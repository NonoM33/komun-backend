defmodule KomunBackend.AI.EmailSummarizer do
  @moduledoc """
  Génère un résumé **public anonymisé** d'un email entrant.

  Pourquoi : la card 📧 affichée dans la timeline d'incident est
  visible par TOUS les voisins du bâtiment (incident `:standard`).
  Afficher le contenu brut d'un email — qui contient typiquement des
  noms, emails, numéros d'appartement, contenu privé — est un risque
  RGPD et social.

  Ce module remplace le contenu brut par un résumé court et neutre
  produit par Groq, qui :

    * remplace les noms par des rôles (le syndic, un voisin, le
      conseil syndical, le promoteur…) ;
    * efface les emails, téléphones, numéros d'appartement ;
    * garde le sujet et l'action attendue ;
    * reste factuel — ni jugement ni reformulation tendancieuse.

  Le contenu brut reste disponible pour le syndic / conseil via le
  fichier d'origine (lien dans la timeline ou audit base) — la
  publication aux voisins est limitée au résumé.
  """

  require Logger

  alias KomunBackend.AI.Groq

  @system_prompt """
  Tu reçois un email ou un document de copropriété qui sera affiché
  PUBLIQUEMENT à tous les voisins d'un immeuble. Tu dois produire un
  résumé court SANS DONNÉES PERSONNELLES.

  Règles strictes :

  1. Aucun nom de personne (remplace par : "un voisin", "le syndic",
     "le conseil syndical", "le promoteur", "un prestataire").
  2. Aucune adresse email, numéro de téléphone, numéro d'appartement
     ou d'étage spécifique. Tu peux dire "le bâtiment B" si c'est dans
     le texte, jamais "appartement 2108".
  3. 2 à 4 phrases maximum, en français clair, neutre, factuel.
  4. Conserve : le sujet du problème, l'action attendue, qui est
     concerné de manière générique (les voisins, le syndic…).
  5. Pas de citation directe.

  Tu retournes UNIQUEMENT un JSON strict :

    {
      "summary": "Résumé public anonyme en 2-4 phrases.",
      "sender_role": "voisin" | "conseil_syndical" | "syndic" |
                     "promoteur" | "prestataire" | "mairie" | "autre"
    }

  Pas de markdown, pas de texte hors JSON.
  """

  @spec summarize(subject :: String.t() | nil, body :: String.t() | nil) ::
          {:ok, %{summary: String.t(), sender_role: String.t()}} | {:error, term()}
  def summarize(subject, body) do
    text = build_input(subject, body)

    if String.trim(text) == "" do
      {:error, :empty}
    else
      messages = [
        %{role: :system, content: @system_prompt},
        %{role: :user, content: text}
      ]

      # Kimi (moonshotai/kimi-k2-instruct) pour cette tâche : meilleurs
      # résumés multilingue/français que gpt-oss-120b sur des emails de
      # copro avec fil de discussion long et signatures bruyantes.
      case Groq.complete(messages,
             model: "moonshotai/kimi-k2-instruct",
             temperature: 0.2,
             max_tokens: 600
           ) do
        {:ok, %{content: raw}} ->
          parse(raw)

        {:error, reason} ->
          Logger.warning("[email_summarizer] Groq failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp build_input(subject, body) do
    s = subject |> to_string() |> String.trim()
    b = body |> to_string() |> String.slice(0, 6000) |> String.trim()
    "Sujet : " <> s <> "\n\nCorps :\n" <> b
  end

  defp parse(content) do
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"summary" => summary} = json} when is_binary(summary) ->
        {:ok,
         %{
           summary: String.trim(summary),
           sender_role: normalize_role(json["sender_role"])
         }}

      {:ok, _} ->
        {:error, :missing_summary}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  @valid_roles ~w(voisin conseil_syndical syndic promoteur prestataire mairie autre)

  defp normalize_role(role) when is_binary(role) do
    if role in @valid_roles, do: role, else: "autre"
  end

  defp normalize_role(_), do: "autre"
end
