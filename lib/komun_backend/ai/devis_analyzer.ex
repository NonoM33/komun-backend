defmodule KomunBackend.AI.DevisAnalyzer do
  @moduledoc """
  Calls Groq to extract structured data from a devis's text content.

  The model is asked to produce JSON conforming to the schema below; we
  parse it, validate the shape, and store the result on the devis.

    %{
      "price_eur"    => float | nil,
      "currency"     => "EUR" | other,
      "pros"         => [String.t()],
      "cons"         => [String.t()],
      "summary"      => String.t(),
      "vendor_name"  => String.t() | nil
    }
  """
  require Logger

  alias KomunBackend.AI.Groq

  @system_prompt """
  Tu es un assistant qui aide un conseil syndical à comparer des devis pour
  une copropriété. À partir du texte brut d'un devis, extrais les
  informations essentielles sous forme JSON strict.

  Réponds UNIQUEMENT avec un objet JSON valide (sans texte libre autour,
  sans balises ```json). Schéma attendu :

  {
    "price_eur": number | null,       // Montant TTC en euros
    "currency": "EUR",                // Devise détectée
    "pros": [string],                 // 3 à 5 avantages concis
    "cons": [string],                 // 2 à 4 vigilances / points négatifs
    "summary": string,                // 2-3 phrases maximum
    "vendor_name": string | null      // Nom de l'entreprise si identifiable
  }

  Règles :
  - Si tu ne trouves pas le prix, mets null (jamais 0).
  - Les pros/cons sont factuels, tirés du texte, formulés en français.
  - N'invente pas de garantie ou de délai non présent dans le devis.
  - La réponse doit être un JSON parsable par Jason.decode!/1.
  """

  @doc """
  Returns `{:ok, analysis_map, model}` or `{:error, reason}`.

  The devis `content_text` is truncated to stay under the model's context
  budget — real devis rarely exceed a couple of pages of text.
  """
  def analyze(content_text, opts \\ []) when is_binary(content_text) do
    trimmed = String.trim(content_text)

    cond do
      trimmed == "" ->
        {:error, :empty_content}

      true ->
        messages = [
          %{role: :system, content: @system_prompt},
          %{role: :user, content: build_user_prompt(trimmed, opts)}
        ]

        case Groq.complete(messages, temperature: 0.1, max_tokens: 800) do
          {:ok, %{content: raw, model: model}} ->
            decode(raw)
            |> case do
              {:ok, map} -> {:ok, map, model}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp build_user_prompt(text, opts) do
    project_hint =
      case Keyword.get(opts, :project_title) do
        nil -> ""
        title -> "Projet de la copropriété : #{title}\n\n"
      end

    # Keep ~6k chars (roughly 1500 tokens) — enough for most devis.
    clipped =
      if String.length(text) > 6_000 do
        String.slice(text, 0, 6_000) <> "\n…[tronqué]"
      else
        text
      end

    "#{project_hint}Contenu du devis :\n\"\"\"\n#{clipped}\n\"\"\""
  end

  defp decode(raw) do
    # Some models wrap in ```json … ``` even when asked not to — strip it.
    cleaned =
      raw
      |> String.trim()
      |> String.replace(~r/\A```(?:json)?\s*/, "")
      |> String.replace(~r/\s*```\z/, "")

    case Jason.decode(cleaned) do
      {:ok, %{} = map} ->
        {:ok, sanitize(map)}

      {:ok, _} ->
        {:error, :non_object_response}

      {:error, _} ->
        Logger.warning("DevisAnalyzer: model returned non-JSON content: #{inspect(raw)}")
        {:error, :invalid_json}
    end
  end

  # Ensure all expected keys exist with sane defaults so the frontend can
  # trust the shape. Extra keys from the model are kept as-is.
  defp sanitize(map) do
    %{
      "price_eur" => num_or_nil(map["price_eur"]),
      "currency" => (map["currency"] || "EUR") |> to_string() |> String.upcase(),
      "pros" => list_of_strings(map["pros"]),
      "cons" => list_of_strings(map["cons"]),
      "summary" => (map["summary"] || "") |> to_string() |> String.trim(),
      "vendor_name" =>
        case map["vendor_name"] do
          nil -> nil
          "" -> nil
          v -> to_string(v)
        end
    }
  end

  defp num_or_nil(n) when is_number(n), do: n * 1.0
  defp num_or_nil(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end
  defp num_or_nil(_), do: nil

  defp list_of_strings(nil), do: []
  defp list_of_strings(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
  defp list_of_strings(_), do: []
end
