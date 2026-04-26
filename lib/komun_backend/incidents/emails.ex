defmodule KomunBackend.Incidents.Emails do
  @moduledoc """
  Sub-context pour la correspondance email d'un incident :
  - `list_for_incident/1` : tous les emails (in/out) triés par date
  - `ingest_pasted/4`     : paste manuel, classifie via Groq sync
  - `send_outbound/3`     : envoi via Resend + persiste l'outbound row
  - `timeline/1`          : merge updates + emails + delivery + lifecycle

  Le contrat JSON et les enums miroitent ceux de la stack Rails — cf.
  `docs/incident-emails.md` côté repo `komun` (Rails) pour la spec
  complète. Les changements de schéma ici doivent rester compatibles.
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Incidents.{Incident, IncidentEmail, EmailParser, EmailClassifier, IncidentEmailMailer}

  # ── Read ────────────────────────────────────────────────────────────────

  @doc "Tous les emails liés à un incident, par ordre chronologique."
  def list_for_incident(%Incident{id: id}), do: list_for_incident(id)
  def list_for_incident(incident_id) when is_binary(incident_id) do
    from(e in IncidentEmail,
      where: e.incident_id == ^incident_id,
      order_by: [
        asc: fragment("COALESCE(?, ?, ?)", e.occurred_at, e.processed_at, e.inserted_at)
      ],
      preload: [:pasted_by]
    )
    |> Repo.all()
  end

  # ── Ingest (paste) ──────────────────────────────────────────────────────

  @type ingest_attrs :: %{
          optional(:raw_text) => String.t(),
          optional(:direction) => String.t() | atom(),
          optional(:from_email) => String.t() | nil,
          optional(:to_email) => String.t() | nil,
          optional(:subject) => String.t() | nil,
          optional(:occurred_at) => DateTime.t() | String.t() | nil,
          optional(:correspondent_kind) => String.t() | atom() | nil
        }

  @doc """
  Ingère un dump email collé manuellement par un user et le rattache à un
  incident. La classification IA tourne **en synchrone** parce que l'UI
  attend le résumé pour l'afficher dans la même réponse — un Groq call
  sub-seconde, on n'a rien à gagner à le mettre en background.

  Retourne `{:ok, %IncidentEmail{}}` ou `{:error, changeset | reason}`.
  En cas d'échec classifier, on persiste tout de même la ligne avec
  `status: :failed` (l'utilisateur a une trace de son paste).
  """
  def ingest_pasted(%Incident{} = incident, user_id, attrs) do
    raw = Map.get(attrs, :raw_text) || Map.get(attrs, "raw_text") || ""

    if String.trim(raw) == "" do
      {:error, :empty_raw_text}
    else
      do_ingest_pasted(incident, user_id, attrs, raw)
    end
  end

  defp do_ingest_pasted(incident, user_id, attrs, raw) do
    parsed =
      EmailParser.parse(raw, %{
        from_email: get_attr(attrs, :from_email),
        to_email: get_attr(attrs, :to_email),
        subject: get_attr(attrs, :subject)
      })

    direction = parse_direction(get_attr(attrs, :direction))
    occurred_at = parse_datetime(get_attr(attrs, :occurred_at)) || parsed.date || now()

    insert_attrs = %{
      direction: direction,
      source: :paste,
      provider: "paste",
      provider_event_id: "paste_#{Ecto.UUID.generate()}",
      from_email: parsed.from_email,
      from_name: parsed.from_name,
      to_email: parsed.to_email,
      cc_emails: parsed.cc_emails,
      reply_to: parsed.reply_to,
      subject: parsed.subject,
      text_body: parsed.text_body,
      headers: parsed.headers,
      raw_text: raw,
      status: :processing,
      occurred_at: occurred_at,
      correspondent_kind: parse_kind(get_attr(attrs, :correspondent_kind)),
      incident_id: incident.id,
      pasted_by_id: user_id
    }

    with {:ok, email} <-
           %IncidentEmail{}
           |> IncidentEmail.changeset(insert_attrs)
           |> Repo.insert() do
      classify_and_finalize(email)
    end
  end

  defp classify_and_finalize(email) do
    case EmailClassifier.classify(email) do
      {:ok, result} ->
        ai_data = Map.merge(result.extracted, %{
          "title" => result.title,
          "priority" => result.priority,
          "incident_category" => result.incident_category,
          "suggested_action" => result.suggested_action
        })

        finalize_attrs = %{
          status: :processed,
          classification: result.classification,
          classification_confidence: result.confidence,
          ai_summary: result.summary,
          ai_data: ai_data,
          processed_at: now(),
          correspondent_kind:
            email.correspondent_kind || infer_kind(result.classification)
        }

        email
        |> IncidentEmail.changeset(finalize_attrs)
        |> Repo.update()
        |> preload_pasted_by()

      {:error, reason} ->
        # On garde la ligne (le user a sa trace) mais on flag failed.
        email
        |> IncidentEmail.changeset(%{
          status: :failed,
          error_message: inspect(reason),
          processed_at: now()
        })
        |> Repo.update()
        |> preload_pasted_by()
    end
  end

  defp infer_kind("syndic_note"), do: :syndic
  defp infer_kind("quote"), do: :contractor
  defp infer_kind("invoice"), do: :contractor
  defp infer_kind("complaint"), do: :neighbor
  defp infer_kind(_), do: nil

  # ── Send (outbound) ─────────────────────────────────────────────────────

  @type send_attrs :: %{
          required(:to) => [String.t()] | String.t(),
          required(:subject) => String.t(),
          required(:body) => String.t(),
          optional(:cc) => [String.t()],
          optional(:bcc) => [String.t()],
          optional(:html) => String.t(),
          optional(:correspondent_kind) => String.t() | atom() | nil,
          optional(:from) => String.t()
        }

  @doc """
  Envoie un email via Resend, persiste un row outbound + auto-CC alias
  d'archivage. Le `provider_message_id` permet de matcher les webhooks de
  delivery (`email.delivered`, `email.opened`, …).
  """
  def send_outbound(%Incident{} = incident, sender_id, attrs) do
    to = normalize_list(get_attr(attrs, :to))
    subject = (get_attr(attrs, :subject) || "") |> to_string() |> String.trim()
    body = (get_attr(attrs, :body) || "") |> to_string()
    html = get_attr(attrs, :html)

    cond do
      to == [] -> {:error, :missing_to}
      subject == "" -> {:error, :missing_subject}
      body == "" and (is_nil(html) or html == "") -> {:error, :missing_body}
      true -> do_send_outbound(incident, sender_id, attrs, to, subject, body, html)
    end
  end

  defp do_send_outbound(incident, sender_id, attrs, to, subject, body, html) do
    cc = normalize_list(get_attr(attrs, :cc))
    bcc = normalize_list(get_attr(attrs, :bcc))

    case IncidentEmailMailer.deliver(incident, %{
           from: get_attr(attrs, :from),
           to: to,
           cc: cc,
           bcc: bcc,
           subject: subject,
           text: body,
           html: html
         }) do
      {:ok, %{message_id: msg_id, cc: full_cc, reply_to: reply_to_addr}} ->
        insert_attrs = %{
          direction: :outbound,
          source: :send,
          provider: "resend",
          provider_message_id: msg_id,
          provider_event_id: "send_#{msg_id || Ecto.UUID.generate()}",
          from_email: get_attr(attrs, :from) || KomunBackend.Incidents.EmailAddressing.from_default(),
          to_email: List.first(to),
          cc_emails: full_cc,
          reply_to: reply_to_addr,
          subject: subject,
          text_body: body,
          html_body: html,
          headers: %{"cc" => Enum.join(full_cc, ", "), "reply-to" => reply_to_addr},
          status: :processed,
          processed_at: now(),
          occurred_at: now(),
          correspondent_kind: parse_kind(get_attr(attrs, :correspondent_kind)),
          incident_id: incident.id,
          pasted_by_id: sender_id,
          delivery_status: "queued",
          delivery_events: [
            %{
              "type" => "queued",
              "at" => DateTime.to_iso8601(now()),
              "payload" => %{"to" => to, "cc" => full_cc, "message_id" => msg_id}
            }
          ]
        }

        %IncidentEmail{}
        |> IncidentEmail.changeset(insert_attrs)
        |> Repo.insert()
        |> preload_pasted_by()

      {:error, reason} ->
        {:error, {:delivery_failed, reason}}
    end
  end

  @doc """
  Append a Resend webhook delivery event (`email.delivered`,
  `email.opened`, `email.bounced`, …) to the matching outbound row.

  Returns `:ok` quand l'event a été enregistré, `:not_found` si on n'a
  aucun outbound avec ce `message_id` (cas légitime : le webhook arrive
  pour un email envoyé hors-app).
  """
  def append_delivery_event(message_id, event_type, payload \\ %{})
      when is_binary(message_id) do
    case Repo.get_by(IncidentEmail, provider_message_id: message_id, direction: :outbound) do
      nil ->
        :not_found

      email ->
        email
        |> IncidentEmail.append_delivery_event_changeset(event_type, payload)
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, _cs} -> :error
        end
    end
  end

  # ── Timeline ────────────────────────────────────────────────────────────

  @doc """
  Construit la timeline complète d'un incident :
  - lifecycle (created, resolved)
  - comments (incident_comments)
  - emails (in/out)
  - delivery events (par mail sortant)

  Retourne une liste de maps déjà sérialisables, triée chronologiquement.
  """
  def timeline(%Incident{} = incident) do
    incident = Repo.preload(incident, [:reporter, comments: :author])
    emails = list_for_incident(incident)

    items =
      lifecycle_items(incident) ++
        comment_items(incident) ++
        email_items(emails) ++
        delivery_items(emails)

    Enum.sort_by(items, & &1.at)
  end

  defp lifecycle_items(incident) do
    base = [
      %{
        id: "lifecycle-created-#{incident.id}",
        kind: "lifecycle",
        at: incident.inserted_at,
        actor: actor_for(incident.reporter),
        payload: %{event: "created", title: incident.title}
      }
    ]

    if incident.resolved_at do
      base ++
        [
          %{
            id: "lifecycle-resolved-#{incident.id}",
            kind: "lifecycle",
            at: incident.resolved_at,
            actor: nil,
            payload: %{event: "resolved", notes: incident.resolution_note}
          }
        ]
    else
      base
    end
  end

  defp comment_items(incident) do
    case incident.comments do
      %Ecto.Association.NotLoaded{} ->
        []

      list ->
        Enum.map(list, fn c ->
          %{
            id: "comment-#{c.id}",
            kind: "update",
            at: c.inserted_at,
            actor: actor_for(c.author),
            payload: %{content: c.body}
          }
        end)
    end
  end

  defp email_items(emails) do
    Enum.map(emails, fn e ->
      kind = if e.direction == :outbound, do: "email_outbound", else: "email_inbound"

      %{
        id: "email-#{e.id}",
        kind: kind,
        at: IncidentEmail.timeline_at(e),
        actor: actor_for(e.pasted_by),
        payload: %{
          subject: e.subject,
          from_email: e.from_email,
          from_name: e.from_name,
          to_email: e.to_email,
          summary: e.ai_summary,
          classification: e.classification,
          source: e.source,
          excerpt: excerpt_for(e),
          email_id: e.id,
          delivery_status: e.delivery_status,
          correspondent_kind: e.correspondent_kind
        }
      }
    end)
  end

  defp delivery_items(emails) do
    emails
    |> Enum.filter(&(&1.direction == :outbound))
    |> Enum.flat_map(fn e ->
      Enum.map(e.delivery_events || [], fn evt ->
        %{
          id: "delivery-#{e.id}-#{evt["type"]}-#{evt["at"]}",
          kind: "delivery",
          at: parse_iso(evt["at"]) || e.inserted_at,
          actor: nil,
          payload: %{
            email_id: e.id,
            event_type: evt["type"],
            subject: e.subject,
            to_email: e.to_email
          }
        }
      end)
    end)
  end

  defp actor_for(nil), do: nil
  defp actor_for(%KomunBackend.Accounts.User{} = u) do
    name =
      cond do
        u.first_name && u.last_name -> "#{u.first_name} #{u.last_name}"
        u.first_name -> u.first_name
        true -> u.email
      end

    %{id: u.id, name: name}
  end

  defp excerpt_for(email) do
    body =
      cond do
        is_binary(email.text_body) and email.text_body != "" -> email.text_body
        is_binary(email.html_body) and email.html_body != "" -> strip_html(email.html_body)
        true -> ""
      end

    body |> String.trim() |> String.slice(0, 280)
  end

  defp strip_html(html), do: String.replace(html, ~r/<[^>]+>/, " ")

  defp parse_iso(nil), do: nil
  defp parse_iso(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp get_attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp parse_direction(v) when v in [:inbound, "inbound"], do: :inbound
  defp parse_direction(v) when v in [:outbound, "outbound"], do: :outbound
  defp parse_direction(_), do: :inbound

  defp parse_kind(nil), do: nil
  defp parse_kind(""), do: nil
  defp parse_kind(v) when is_atom(v), do: v
  defp parse_kind(v) when is_binary(v) do
    case v do
      "syndic" -> :syndic
      "contractor" -> :contractor
      "neighbor" -> :neighbor
      "public_admin" -> :public_admin
      "other" -> :other
      _ -> nil
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp normalize_list(nil), do: []
  defp normalize_list(v) when is_binary(v), do: v |> String.split(~r/[,;\s]+/) |> Enum.reject(&(&1 == ""))
  defp normalize_list(v) when is_list(v), do: Enum.reject(v, &(&1 in [nil, ""]))

  defp preload_pasted_by({:ok, email}), do: {:ok, Repo.preload(email, :pasted_by)}
  defp preload_pasted_by(other), do: other
end
