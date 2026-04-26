defmodule KomunBackend.Incidents.EmailClassifier do
  @moduledoc """
  Classifie un email lié à un incident via Groq.

  Sortie : `{:ok, %{classification, confidence, title, summary, priority,
  incident_category, suggested_action, is_spam, extracted}}` — même contrat
  que la stack Rails (`InboundEmailClassifierService.Result`).

  Erreurs : `{:error, :missing_api_key}` (en test si pas de clé) ou
  `{:error, raison}`. L'appelant décide quoi faire (mark email as failed).
  """

  alias KomunBackend.AI.Groq
  alias KomunBackend.Incidents.IncidentEmail

  @categories ~w[complaint quote syndic_note incident_report general_info invoice spam other]
  @priorities ~w[low normal high urgent]
  @incident_categories ~w[other elevator plumbing electricity heating security cleaning parking garden noise water_damage pest]

  @type result :: %{
          classification: String.t(),
          confidence: float() | nil,
          title: String.t(),
          summary: String.t(),
          priority: String.t(),
          incident_category: String.t(),
          suggested_action: String.t() | nil,
          is_spam: boolean(),
          extracted: map()
        }

  @spec classify(IncidentEmail.t()) :: {:ok, result} | {:error, term}
  def classify(%IncidentEmail{} = email) do
    messages = [
      %{role: :system, content: system_prompt()},
      %{role: :user, content: user_prompt(email)}
    ]

    case Groq.complete(messages, max_tokens: 1024, temperature: 0.2) do
      {:ok, %{content: content}} ->
        parse_groq_response(content, email)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp system_prompt do
    """
    Tu es un assistant qui classe des emails entrants pour une plateforme
    communautaire d'immeuble (Komun). Les emails peuvent venir de résidents,
    de voisins, du syndic, de prestataires, etc.

    Ta sortie DOIT être un JSON unique strictement conforme à ce schéma:
    {
      "classification": "complaint|quote|syndic_note|incident_report|general_info|invoice|spam|other",
      "confidence": 0.0-1.0,
      "title": "titre court (max 80 car.)",
      "summary": "résumé en français (max 400 car.)",
      "priority": "low|normal|high|urgent",
      "incident_category": "other|elevator|plumbing|electricity|heating|security|cleaning|parking|garden|noise|water_damage|pest",
      "suggested_action": "phrase d'action recommandée pour les admins",
      "is_spam": true|false,
      "extracted": {
        "company_name": null,
        "amount_cents": null,
        "due_date": null,
        "location": null,
        "contact_email": null,
        "contact_phone": null
      }
    }

    Règles:
    - "complaint": plainte d'un voisin (bruit, comportement, propreté...).
    - "quote" (devis): proposition commerciale chiffrée d'un prestataire.
    - "syndic_note": communication du syndic (note, AG, charges, travaux...).
    - "incident_report": signalement technique (fuite, ascenseur, panne...).
    - "invoice": facture reçue.
    - "general_info": information neutre (newsletter interne, annonce).
    - "spam": publicité non sollicitée ou phishing.
    - "other": rien de pertinent.
    - Pour incident_category, choisis UNIQUEMENT dans la liste autorisée.
    - "priority": urgent si danger/dégât actif, high si impact fort, normal par défaut.
    - "amount_cents": montant total TTC en centimes d'euros, sinon null.
    - Réponds UNIQUEMENT avec le JSON, sans markdown ni commentaire.
    """
  end

  defp user_prompt(email) do
    body =
      cond do
        is_binary(email.text_body) and email.text_body != "" -> email.text_body
        is_binary(email.html_body) and email.html_body != "" -> strip_html(email.html_body)
        true -> ""
      end
      |> String.slice(0, 6000)

    """
    FROM: #{email.from_email || "?"} (#{email.from_name || ""})
    TO: #{email.to_email || "?"}
    SUBJECT: #{email.subject || ""}

    BODY:
    #{body}
    """
  end

  defp parse_groq_response(content, email) do
    case extract_json(content) do
      nil ->
        {:error, "no JSON in classifier response: #{String.slice(content, 0, 200)}"}

      json_str ->
        case Jason.decode(json_str) do
          {:ok, data} when is_map(data) ->
            {:ok, normalize(data, email)}

          {:error, e} ->
            {:error, "invalid JSON from classifier: #{inspect(e)}"}
        end
    end
  end

  defp extract_json(content) do
    case Regex.run(~r/\{[\s\S]*\}/, content) do
      [json] -> json
      _ -> nil
    end
  end

  defp normalize(data, email) do
    classification = string_in(data["classification"], @categories, "other")
    priority = string_in(data["priority"], @priorities, "normal")
    incident_category = string_in(data["incident_category"], @incident_categories, "other")
    extracted = if is_map(data["extracted"]), do: data["extracted"], else: %{}

    %{
      classification: classification,
      confidence: clamp_float(data["confidence"]),
      title: trim(data["title"], 80) |> nonblank_or(email.subject) |> trim(80),
      summary: trim(data["summary"], 400),
      priority: priority,
      incident_category: incident_category,
      suggested_action: trim(data["suggested_action"], 240) |> nonblank,
      is_spam: data["is_spam"] == true,
      extracted: extracted
    }
  end

  defp string_in(v, allowed, default) when is_binary(v) do
    if v in allowed, do: v, else: default
  end
  defp string_in(_, _, default), do: default

  defp trim(nil, _max), do: ""
  defp trim(v, max) when is_binary(v) do
    v |> String.trim() |> String.slice(0, max)
  end
  defp trim(_, _), do: ""

  defp nonblank(""), do: nil
  defp nonblank(v), do: v
  defp nonblank_or("", fallback), do: to_string(fallback || "")
  defp nonblank_or(v, _), do: v

  defp clamp_float(nil), do: nil
  defp clamp_float(v) when is_number(v), do: v |> max(0.0) |> min(1.0) |> :erlang.float()
  defp clamp_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f |> max(0.0) |> min(1.0)
      :error -> nil
    end
  end
  defp clamp_float(_), do: nil

  defp strip_html(html) when is_binary(html) do
    html |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()
  end
end
