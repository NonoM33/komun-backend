defmodule KomunBackend.InboundEmails do
  @moduledoc """
  Pipeline d'ingestion d'emails — helpers réutilisables.

  Mode dégradé volontaire pour le MVP : on **crée systématiquement
  un nouvel incident** par fichier ingéré. Pas de routage AI append-vs-
  create — le module `KomunBackend.AI.IncidentRouter` n'est pas
  encore présent sur stg/prod.

  ## RGPD / Privacy

  Les incidents `:standard` sont visibles par tous les voisins du
  bâtiment. Le contenu brut d'un email entrant peut contenir des noms,
  emails, numéros d'appartement — données qui ne doivent pas fuiter.

  On utilise `KomunBackend.AI.EmailSummarizer` pour produire un résumé
  public anonymisé qui remplace le contenu brut dans la card 📧
  publiée. Le brut est consultable via le fichier d'origine (lien) en
  cas de besoin du syndic / conseil.
  """

  require Logger

  alias KomunBackend.{Incidents, Repo}
  alias KomunBackend.Accounts.User
  alias KomunBackend.AI.EmailSummarizer

  @doc "Récupère un super_admin pour porter les commentaires système."
  def system_author do
    import Ecto.Query

    case Repo.one(from(u in User, where: u.role == :super_admin, limit: 1)) do
      nil -> {:error, :no_system_user}
      user -> {:ok, user}
    end
  end

  @role_labels %{
    "voisin" => "un voisin",
    "conseil_syndical" => "le conseil syndical",
    "syndic" => "le syndic",
    "promoteur" => "le promoteur",
    "prestataire" => "un prestataire",
    "mairie" => "la mairie",
    "autre" => "un correspondant"
  }

  @doc """
  Formate la card 📧 publique. Le `email` est attendu **déjà
  anonymisé** : `body` doit contenir le résumé public, `from_name`
  doit être un rôle générique (pas un nom de personne).
  """
  def format_email_body(email) do
    subject = stringy(email, :subject)
    sender_label = sender_label(email)
    body = stringy(email, :body)
    date_label = stringy(email, :received_at)

    "📧 **" <> subject <> "**\n" <>
      "Émetteur : " <> sender_label <> "\n" <>
      "Date : " <> date_label <> "\n\n" <>
      body
  end

  @doc """
  Crée un incident à partir d'un email + 1er commentaire 📧 anonymisé.

  Pipeline :
    1. `EmailSummarizer.summarize/2` produit un résumé public + rôle
       de l'expéditeur (anonymisé).
    2. On remplace `email.body` par le résumé et `email.from_name` par
       le rôle générique avant d'appeler `format_email_body`.
    3. Si Groq échoue, on tombe en fallback : titre = sujet, body =
       message générique "[Document importé — voir pièce jointe]".

  Renvoie `{:ok, %{action: :create, incident_id: id}}` ou
  `{:error, reason}`.
  """
  def ingest_email(building_id, author_id, email)
      when is_binary(building_id) and is_binary(author_id) do
    sanitized = anonymize(email)

    case create_incident_from_email(building_id, author_id, sanitized) do
      {:ok, incident} -> {:ok, %{action: :create, incident_id: incident.id}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Demande à Groq un résumé anonyme et remplace les champs brut. Si
  # Groq échoue, on remplace quand même le body brut par un placeholder
  # neutre — pas question de publier le contenu intégral aux voisins.
  defp anonymize(email) do
    subject = stringy(email, :subject)
    body = stringy(email, :body)

    case EmailSummarizer.summarize(subject, body) do
      {:ok, %{summary: summary, sender_role: role}} ->
        email
        |> Map.put(:body, summary)
        |> Map.put(:from_name, Map.get(@role_labels, role, "un correspondant"))
        |> Map.put(:from, "")
        |> Map.put(:to, nil)
        |> Map.put(:cc, nil)

      {:error, reason} ->
        Logger.warning("[inbound_emails] anonymize fallback: #{inspect(reason)}")

        email
        |> Map.put(:body, "[Document reçu — résumé indisponible. Voir la pièce jointe pour le détail.]")
        |> Map.put(:from_name, "un correspondant")
        |> Map.put(:from, "")
        |> Map.put(:to, nil)
        |> Map.put(:cc, nil)
    end
  end

  defp create_incident_from_email(building_id, author_id, email) do
    title =
      email
      |> stringy(:subject)
      |> String.slice(0, 200)
      |> ensure_min_length("Email entrant — sujet à préciser")

    description =
      email
      |> stringy(:body)
      |> String.slice(0, 1500)
      |> case do
        "" -> "(résumé indisponible)"
        s -> s
      end

    attrs = %{
      "title" => title,
      "description" => description,
      "category" => "autre",
      "severity" => "medium"
    }

    with {:ok, incident} <- Incidents.create_incident(building_id, author_id, attrs),
         {:ok, _comment} <-
           Incidents.add_comment(incident.id, author_id, %{"body" => format_email_body(email)}) do
      {:ok, incident}
    end
  end

  # ── Helpers privés ────────────────────────────────────────────────────

  defp sender_label(email) do
    name = stringy(email, :from_name)
    if name == "", do: "un correspondant", else: name
  end

  defp stringy(email, key) when is_atom(key) do
    str_key = Atom.to_string(key)
    value = email[key] || email[str_key]
    to_string_safe(value)
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(s) when is_binary(s), do: s
  defp to_string_safe(%DateTime{} = dt), do: Calendar.strftime(dt, "%d/%m/%Y %H:%M")
  defp to_string_safe(other), do: to_string(other)

  defp ensure_min_length(s, fallback) do
    if String.length(s) >= 5, do: s, else: fallback
  end
end
