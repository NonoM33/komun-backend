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
  alias KomunBackend.Incidents.{Incident, LocalStorage}
  alias KomunBackend.InboundEmails.EmlParser
  alias KomunBackend.AI.{EmailSummarizer, IncidentRouter}

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

    "📧 **" <>
      subject <>
      "**\n" <>
      "De : **" <>
      sender_name <>
      "** <" <>
      sender_email <>
      ">\n" <>
      "À : " <>
      to <>
      "\n" <>
      cc_line <>
      "Date : " <>
      date_label <>
      "\n\n" <>
      body
  end

  @doc """
  Ingère un email :

    1. Demande au routeur AI (`IncidentRouter.route/2`) si l'email
       continue un dossier ouvert ou doit créer un nouveau.
    2. Si append → ajoute un commentaire 📧 brut au dossier.
    3. Si create → nouvel incident avec :
        * `incident.description` = résumé Groq anonyme (visible voisins)
        * 1er commentaire 📧 = contenu brut intégral

  Si des `attachments` sont fournies (issues de
  `EmlParser.extract_attachments/1`), elles sont validées (mime + taille
  via `LocalStorage`), persistées sur disque, et rattachées à l'incident
  via `Incidents.attach_file/3`. Quand au moins une PJ a été attachée,
  on strippe le placeholder « [Pièce jointe encodée…] » du body brut
  pour ne pas faire croire que la PJ est perdue.

    Le redact côté `IncidentController.comment_json/2` masque le brut
    aux non-privilégiés à la lecture.

  Renvoie `{:ok, %{action: :append|:create, incident_id, comment_id?, attachments_count}}`
  ou `{:error, reason}`.
  """
  def ingest_email(building_id, author_id, email, attachments \\ [])
      when is_binary(building_id) and is_binary(author_id) and is_list(attachments) do
    {kept, rejected} = filter_attachments(attachments)
    log_rejected(rejected)

    email = maybe_strip_attachment_placeholder(email, kept)
    open_incidents = list_open_incidents(building_id)

    result =
      case IncidentRouter.route(email, open_incidents) do
        {:append, incident_id} ->
          append_email_to_incident(incident_id, author_id, email)

        :create ->
          case create_incident_from_email(building_id, author_id, email) do
            {:ok, incident} -> {:ok, %{action: :create, incident_id: incident.id}}
            {:error, reason} -> {:error, reason}
          end
      end

    case result do
      {:ok, %{incident_id: incident_id} = info} ->
        attached_count = save_and_attach(incident_id, author_id, kept)
        {:ok, Map.put(info, :attachments_count, attached_count)}

      err ->
        err
    end
  end

  defp append_email_to_incident(incident_id, author_id, email) do
    case Incidents.add_comment(incident_id, author_id, %{"body" => format_email_body(email)}) do
      {:ok, comment} ->
        {:ok, %{action: :append, incident_id: incident_id, comment_id: comment.id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Attachments ──────────────────────────────────────────────────────

  # Sépare les PJ qu'on garde (mime ok + taille ok) de celles qu'on
  # rejette (avec une raison loggable).
  defp filter_attachments(attachments) do
    Enum.reduce(attachments, {[], []}, fn att, {kept, rejected} ->
      cond do
        att.content_type not in LocalStorage.allowed_mime_types() ->
          {kept, [{att, :mime_not_allowed} | rejected]}

        byte_size(att.bytes) > LocalStorage.max_upload_bytes() ->
          {kept, [{att, :too_large} | rejected]}

        byte_size(att.bytes) == 0 ->
          {kept, [{att, :empty} | rejected]}

        true ->
          {[att | kept], rejected}
      end
    end)
    |> then(fn {k, r} -> {Enum.reverse(k), Enum.reverse(r)} end)
  end

  defp log_rejected(rejected) do
    Enum.each(rejected, fn {att, reason} ->
      Logger.info(
        "[inbound_emails] attachment skipped — reason=#{reason} filename=#{inspect(att.filename)} mime=#{att.content_type} bytes=#{byte_size(att.bytes)}"
      )
    end)
  end

  # Si au moins 1 PJ va être réellement attachée, on retire le placeholder
  # « [Pièce jointe encodée — non incluse…] » du body brut — sinon le
  # commentaire 📧 ferait croire que la PJ est perdue alors qu'elle est
  # listée juste à côté dans la timeline.
  defp maybe_strip_attachment_placeholder(email, []), do: email

  defp maybe_strip_attachment_placeholder(email, _kept) do
    placeholder = EmlParser.placeholder_attachment_text()
    body = stringy(email, :body)

    if String.contains?(body, placeholder) do
      new_body =
        body
        |> String.replace(placeholder, "")
        |> String.replace(~r/\n{3,}/, "\n\n")
        |> String.trim()

      Map.put(email, :body, new_body)
    else
      email
    end
  end

  defp save_and_attach(_incident_id, _author_id, []), do: 0

  defp save_and_attach(incident_id, author_id, kept) do
    user = Repo.get(User, author_id)

    Enum.reduce(kept, 0, fn att, count ->
      case persist_attachment(incident_id, user, att) do
        :ok -> count + 1
        :error -> count
      end
    end)
  end

  defp persist_attachment(incident_id, %User{} = user, att) do
    with {:ok, %{relative_path: rel, size: size}} <-
           LocalStorage.save_bytes(att.bytes, att.filename, incident_id),
         attrs = %{
           "kind" => LocalStorage.infer_kind(nil, att.content_type),
           "filename" => att.filename,
           "file_url" => "/" <> rel,
           "file_size_bytes" => size,
           "mime_type" => att.content_type
         },
         {:ok, _file} <- Incidents.attach_file(incident_id, user, attrs) do
      :ok
    else
      err ->
        Logger.warning(
          "[inbound_emails] persist attachment failed for incident=#{incident_id} filename=#{inspect(att.filename)}: #{inspect(err)}"
        )

        :error
    end
  end

  # Incidents `:open` + `:in_progress` du building. Pas de preload —
  # le routeur AI a juste besoin de id/title/severity/micro_summary/
  # description.
  defp list_open_incidents(building_id) do
    import Ecto.Query

    Repo.all(
      from i in Incident,
        where: i.building_id == ^building_id and i.status in [:open, :in_progress],
        order_by: [desc: i.inserted_at],
        limit: 50
    )
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
