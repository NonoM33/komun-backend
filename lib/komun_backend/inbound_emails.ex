defmodule KomunBackend.InboundEmails do
  @moduledoc """
  Pipeline d'ingestion d'emails — helpers réutilisables.

  Mode dégradé volontaire pour le MVP : on **crée systématiquement
  un nouvel incident** par fichier ingéré. Pas de routage AI append-vs-
  create — le module `KomunBackend.AI.IncidentRouter` n'est pas
  encore présent sur stg/prod.

  ## RGPD / Privacy — split résumé public / contenu brut

  - L'incident `description` reçoit un **résumé public anonymisé**
    (Groq, sans noms/emails/numéros d'appartement). C'est ce que les
    voisins voient quand ils ouvrent l'incident.

  - Le commentaire 📧 reçoit le **contenu brut** intégral (vrais
    `from`, `to`, `cc`, body). Le backend `IncidentController.comment_json/2`
    se charge déjà de redacter ce body pour les non-privilégiés (cf
    `email_imported_comment?` + `redact_email_body`).

    → Conseil / admin voient le brut.
    → Voisins voient juste un placeholder "[Échange réservé au conseil]"
      + le résumé public déjà visible dans la `description`.

  Pas besoin de toucher au schema ou aux endpoints existants : la
  redaction côté lecture est déjà en place.
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

  @doc """
  Formate la card 📧 du commentaire — **brut**, avec vrais headers
  (from, to, cc). La redaction côté `comment_json` masquera ce contenu
  aux non-privilégiés à la lecture.
  """
  def format_email_body(email) do
    subject = stringy(email, :subject)
    sender_email = stringy(email, :from)
    sender_name = stringy(email, :from_name) |> default_to(sender_email) |> default_to("Inconnu")
    to = stringy(email, :to)
    body = stringy(email, :body)
    date_label = stringy(email, :received_at)

    cc_line =
      case email[:cc] || email["cc"] do
        nil -> ""
        "" -> ""
        list when is_list(list) and list != [] -> "Cc : " <> Enum.join(list, ", ") <> "\n"
        s when is_binary(s) and s != "" -> "Cc : " <> s <> "\n"
        _ -> ""
      end

    "📧 **" <> subject <> "**\n" <>
      "De : **" <> sender_name <> "** <" <> sender_email <> ">\n" <>
      "À : " <> to <> "\n" <>
      cc_line <>
      "Date : " <> date_label <> "\n\n" <>
      body
  end

  @doc """
  Crée un incident à partir d'un email :
    * `incident.description` = résumé Groq anonyme (visible voisins)
    * 1er commentaire 📧 = contenu brut intégral (redacté côté lecture
      pour les non-privilégiés)
  """
  def ingest_email(building_id, author_id, email)
      when is_binary(building_id) and is_binary(author_id) do
    case create_incident_from_email(building_id, author_id, email) do
      {:ok, incident} -> {:ok, %{action: :create, incident_id: incident.id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_incident_from_email(building_id, author_id, email) do
    title =
      email
      |> stringy(:subject)
      |> String.slice(0, 200)
      |> ensure_min_length("Email entrant — sujet à préciser")

    description = build_public_description(email)

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

  # Le résumé public anonyme va dans la `description` de l'incident,
  # qui est servie telle quelle aux voisins par `IncidentController`.
  # Si Groq échoue, fallback neutre — jamais le body brut publié.
  defp build_public_description(email) do
    subject = stringy(email, :subject)
    body = stringy(email, :body)

    case EmailSummarizer.summarize(subject, body) do
      {:ok, %{summary: summary}} ->
        summary
        |> String.trim()
        |> case do
          "" -> fallback_description()
          s -> s
        end

      {:error, reason} ->
        Logger.warning("[inbound_emails] summarize fallback: #{inspect(reason)}")
        fallback_description()
    end
  end

  defp fallback_description do
    "Email reçu — un membre du conseil syndical examinera le contenu et le résumera ici dès que possible."
  end

  # ── Helpers privés ────────────────────────────────────────────────────

  defp stringy(email, key) when is_atom(key) do
    str_key = Atom.to_string(key)
    value = email[key] || email[str_key]
    to_string_safe(value)
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(s) when is_binary(s), do: s
  defp to_string_safe(%DateTime{} = dt), do: Calendar.strftime(dt, "%d/%m/%Y %H:%M")
  defp to_string_safe(other), do: to_string(other)

  defp default_to("", fallback), do: fallback
  defp default_to(value, _fallback), do: value

  defp ensure_min_length(s, fallback) do
    if String.length(s) >= 5, do: s, else: fallback
  end
end
