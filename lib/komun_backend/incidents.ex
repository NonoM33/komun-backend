defmodule KomunBackend.Incidents do
  @moduledoc "Incidents context — scoped by building."

  import Ecto.Query
  alias Ecto.Multi
  alias KomunBackend.Repo
  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.BuildingMember
  alias KomunBackend.Accounts.User
  alias KomunBackend.Doleances.Doleance
  alias KomunBackend.Incidents.{Incident, IncidentComment, IncidentEvent}
  alias KomunBackend.Notifications
  alias KomunBackend.Notifications.Jobs.SendFollowUpEmailJob
  alias KomunBackendWeb.BuildingChannel

  # Rôles qui peuvent voir les incidents flaggés `:council_only`. On garde
  # la liste alignée avec celle du controller — duplication délibérée pour
  # éviter une dépendance circulaire avec Web.
  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  # Rôles autorisés à *relancer* le syndic. Plus restreint que les
  # privilégiés-lecture : on ne veut pas que tous les coproprietaires
  # spamment le syndic. Le conseil syndical fait l'arbitrage.
  @follow_up_roles [:super_admin, :syndic_manager, :president_cs, :membre_cs]

  # Délai minimum avant d'envoyer un nouvel email de relance pour le même
  # dossier — la push reste systématique, l'email lui est anti-spam.
  @follow_up_email_debounce_hours 24

  @doc """
  Vrai si `user` peut voir les incidents `:council_only` du bâtiment.
  Accepte aussi `nil` côté `user` — renvoie `false`.
  """
  def privileged?(_building_id, nil), do: false
  def privileged?(_building_id, %User{role: :super_admin}), do: true
  def privileged?(building_id, %User{} = user) do
    member_role = Buildings.get_member_role(building_id, user.id)
    user.role in @privileged_roles or member_role in @privileged_roles
  end

  @doc """
  Vrai si `user` a le droit d'envoyer une relance officielle au syndic
  sur ce bâtiment. C'est volontairement plus restrictif que `privileged?` :
  un membre du conseil syndical (président_cs / membre_cs) ou un compte
  syndic peut relancer ; un coproprietaire simple, non.
  """
  def follow_up_allowed?(_building_id, nil), do: false
  def follow_up_allowed?(_building_id, %User{role: :super_admin}), do: true
  def follow_up_allowed?(building_id, %User{} = user) do
    member_role = Buildings.get_member_role(building_id, user.id)
    user.role in @follow_up_roles or member_role in @follow_up_roles
  end

  def list_incidents(building_id, filters \\ %{}, viewer \\ nil) do
    base =
      from(i in Incident,
        where: i.building_id == ^building_id,
        # comment_json/1 reads comment.author, so :author has to be preloaded
        # here too — otherwise we hand it a %Ecto.Association.NotLoaded{} and
        # the whole response crashes with a KeyError on :first_name.
        preload: [:reporter, :assignee, comments: :author],
        order_by: [desc: i.inserted_at]
      )

    base
    |> apply_filter(:status, filters["status"])
    |> apply_filter(:severity, filters["severity"])
    |> apply_visibility(building_id, viewer)
    |> Repo.all()
  end

  defp apply_filter(q, _field, nil), do: q
  defp apply_filter(q, :status, v), do: where(q, [i], i.status == ^v)
  defp apply_filter(q, :severity, v), do: where(q, [i], i.severity == ^v)

  # Si le viewer n'est pas membre privilégié, on cache les incidents
  # `:council_only` — ils ne sortent ni de la liste ni des endpoints qui
  # passent par cette fonction.
  defp apply_visibility(q, building_id, viewer) do
    if privileged?(building_id, viewer) do
      q
    else
      where(q, [i], i.visibility == :standard)
    end
  end

  def get_incident!(id), do: Repo.get!(Incident, id) |> Repo.preload([:reporter, :assignee, comments: :author])

  @doc "Same as get_incident!/1 but returns nil when missing."
  def get_incident(id), do: Repo.get(Incident, id)

  def create_incident(building_id, user_id, attrs) do
    now = utc_now()

    attrs =
      Map.merge(attrs, %{
        "building_id" => building_id,
        "reporter_id" => user_id,
        "last_action_at" => now
      })

    with {:ok, incident} <- %Incident{} |> Incident.changeset(attrs) |> Repo.insert() do
      incident = Repo.preload(incident, [:reporter, :assignee])

      # Timeline : un dossier démarre toujours par un :created.
      {:ok, _event} = record_event(incident, :created, user_id, %{})

      if incident.visibility == :council_only do
        # Confidentialité maximale : on ne diffuse pas via le canal partagé
        # du bâtiment (sinon les autres résidents recevraient l'event), on
        # ne notifie que les membres privilégiés et on saute l'IA — un LLM
        # qui paraphrase une plainte sensible est un risque de fuite.
        notify_privileged_members(
          building_id,
          "Nouveau signalement confidentiel",
          "Un signalement a été envoyé au conseil syndical.",
          %{type: "incident", incident_id: incident.id, building_id: building_id}
        )
      else
        BuildingChannel.broadcast_incident(building_id, incident)

        Notifications.send_to_building(
          building_id,
          "Nouvel incident signalé",
          incident.title,
          %{type: "incident", incident_id: incident.id, building_id: building_id}
        )

        # Fire-and-forget AI triage. Groq fills ai_answer on the incident and
        # the resident polls for the update. Failure leaves the incident as-is.
        KomunBackend.AI.Triage.triage_incident_async(incident)

        # Notifications ciblées de voisinage (water_leak → en dessous,
        # noise → voisins de palier). Pas de notif si subtype absent.
        maybe_notify_neighbors(incident)
      end

      {:ok, incident}
    end
  end

  # Jobs Oban dédiés — on n'envoie pas de notif voisinage pour les incidents
  # `:council_only` (déjà filtré en amont) ni quand le `subtype` est absent
  # ou `:other`. Le `reporter` doit être lié à un BuildingMember avec un
  # `primary_lot_id` ; sinon le job no-op silencieusement.
  defp maybe_notify_neighbors(%Incident{subtype: :water_leak, id: id}) do
    %{incident_id: id}
    |> KomunBackend.Notifications.Jobs.NotifyUnitBelowJob.new()
    |> Oban.insert()
  end

  defp maybe_notify_neighbors(%Incident{subtype: :noise, id: id}) do
    %{incident_id: id}
    |> KomunBackend.Notifications.Jobs.NotifySameFloorJob.new()
    |> Oban.insert()
  end

  defp maybe_notify_neighbors(_), do: :ok

  # Notifie uniquement les membres privilégiés (syndic / conseil) du
  # bâtiment — utilisé quand un incident est `:council_only` pour ne pas
  # alerter tout l'immeuble. Un user est "privilégié" si :
  #   - son rôle BuildingMember est :president_cs ou :membre_cs, OU
  #   - son rôle User global est :super_admin / :syndic_manager / :syndic_staff
  defp notify_privileged_members(building_id, title, body, data) do
    Enum.each(privileged_users(building_id), fn user ->
      Notifications.send_to_user(user, title, body, data)
    end)

    :ok
  end

  defp privileged_users(building_id) do
    council_member_roles = [:president_cs, :membre_cs]
    syndic_user_roles = [:super_admin, :syndic_manager, :syndic_staff]

    from(m in BuildingMember,
      join: u in User,
      on: u.id == m.user_id,
      where:
        m.building_id == ^building_id and
          m.is_active == true and
          (m.role in ^council_member_roles or u.role in ^syndic_user_roles),
      select: u,
      distinct: true
    )
    |> Repo.all()
  end

  @doc """
  Confirms (or re-opens) the AI-generated answer. Only privileged members
  should call this — the controller gates access.
  """
  def confirm_ai_answer(%Incident{} = incident, user_id) do
    now = utc_now()

    with {:ok, updated} <-
           incident
           |> Incident.changeset(%{
             ai_answer_confirmed_at: now,
             ai_answer_confirmed_by_id: user_id,
             last_action_at: now
           })
           |> Repo.update() do
      record_event(updated, :ai_confirmed, user_id, %{})
      {:ok, updated}
    end
  end

  def unconfirm_ai_answer(%Incident{} = incident) do
    incident
    |> Incident.changeset(%{
      ai_answer_confirmed_at: nil,
      ai_answer_confirmed_by_id: nil
    })
    |> Repo.update()
  end

  @doc """
  Let privileged members edit the AI answer (to complete, correct, or
  rewrite the text). When `:confirm` is true, the new text is also marked
  validated in the same update, so the resident-facing banner flips from
  "proposition" to "validée" in one click.

  Blank text clears both the answer and any confirmation — the resident
  stops seeing an AI banner entirely.
  """
  def update_ai_answer(%Incident{} = incident, ai_answer, user_id, opts \\ []) do
    confirm? = Keyword.get(opts, :confirm, false)
    now = utc_now()

    trimmed =
      case ai_answer do
        nil -> ""
        text when is_binary(text) -> String.trim(text)
        _ -> ""
      end

    attrs =
      cond do
        trimmed == "" ->
          %{
            ai_answer: nil,
            ai_answered_at: nil,
            ai_answer_confirmed_at: nil,
            ai_answer_confirmed_by_id: nil
          }

        confirm? ->
          %{
            ai_answer: trimmed,
            ai_answered_at: incident.ai_answered_at || now,
            ai_answer_confirmed_at: now,
            ai_answer_confirmed_by_id: user_id
          }

        true ->
          %{
            ai_answer: trimmed,
            ai_answered_at: incident.ai_answered_at || now
          }
      end

    with {:ok, updated} <- incident |> Incident.changeset(attrs) |> Repo.update() do
      BuildingChannel.broadcast_incident(updated.building_id, updated)

      if confirm? and trimmed != "" do
        record_event(updated, :ai_confirmed, user_id, %{})
      end

      {:ok, updated}
    end
  end

  def update_incident(incident, attrs) do
    previous_status = incident.status
    now = utc_now()

    attrs_with_action =
      attrs
      |> stringify_keys()
      |> Map.put_new("last_action_at", now)

    with {:ok, updated} <- incident |> Incident.changeset(attrs_with_action) |> Repo.update() do
      updated = Repo.preload(updated, [:reporter, :assignee])

      if updated.status != previous_status do
        record_event(updated, :status_change, nil, %{
          from: to_string(previous_status),
          to: to_string(updated.status)
        })
      end

      BuildingChannel.broadcast_incident(updated.building_id, updated)
      {:ok, updated}
    end
  end

  def resolve_incident(incident, note) do
    with {:ok, resolved} <- incident |> Incident.resolve_changeset(note) |> Repo.update() do
      record_event(resolved, :status_change, nil, %{
        from: to_string(incident.status),
        to: to_string(resolved.status)
      })

      BuildingChannel.broadcast_incident(resolved.building_id, resolved)
      {:ok, resolved}
    end
  end

  def add_comment(incident_id, author_id, attrs) do
    attrs = Map.merge(attrs, %{"incident_id" => incident_id, "author_id" => author_id})

    with {:ok, comment} <- %IncidentComment{} |> IncidentComment.changeset(attrs) |> Repo.insert() do
      incident = get_incident!(incident_id)
      author = Repo.get(User, author_id)

      # Distinguer une réponse du syndic d'un commentaire résident, c'est
      # ce qui permet à la timeline de dire "le syndic a répondu" et au
      # frontend d'afficher "Vu par le syndic" sur la carte.
      event_type =
        if author && author.role in @privileged_roles,
          do: :syndic_action,
          else: :comment_added

      record_event(incident, event_type, author_id, %{
        comment_id: to_string(comment.id),
        is_internal: comment.is_internal
      })

      Notifications.send_to_building(
        incident.building_id,
        "Nouvelle réponse à un incident",
        incident.title,
        %{type: "incident_comment", incident_id: incident_id, building_id: incident.building_id}
      )

      {:ok, comment}
    end
  end

  # ── Suivi des dossiers (cases) ───────────────────────────────────────────

  @doc """
  Liste les dossiers ouverts (status `:open` ou `:in_progress`) du
  bâtiment, avec metrics calculées (`days_open`, `days_since_last_action`,
  `follow_up_count`) et le dernier événement de la timeline. Triés par
  `last_action_at` ascendant — le plus en attente d'abord.

  Respecte la visibilité : un viewer non privilégié ne voit pas les
  dossiers `:council_only`.
  """
  def list_open_cases(building_id, viewer \\ nil) do
    base =
      from(i in Incident,
        where: i.building_id == ^building_id,
        where: i.status in [:open, :in_progress],
        preload: [:reporter, :assignee, :linked_doleance],
        order_by: [asc_nulls_first: i.last_action_at]
      )

    base
    |> apply_visibility(building_id, viewer)
    |> Repo.all()
    |> Enum.map(&attach_case_metrics/1)
  end

  defp attach_case_metrics(%Incident{} = inc) do
    now = utc_now()
    last_event = last_event_for(inc.id)

    metrics = %{
      days_open: diff_in_days(inc.inserted_at, now),
      days_since_last_action:
        diff_in_days(inc.last_action_at || inc.inserted_at, now),
      follow_up_count: inc.follow_up_count || 0
    }

    # On enrichit l'incident avec les metrics et le dernier event sans
    # casser sa nature de struct — `Map.put/3` préserve `__struct__:`,
    # donc l'appelant peut continuer à pattern-matcher `%Incident{}`.
    inc
    |> Map.put(:metrics, metrics)
    |> Map.put(:last_event, last_event)
  end

  defp last_event_for(incident_id) do
    from(e in IncidentEvent,
      where: e.incident_id == ^incident_id,
      order_by: [desc: e.inserted_at],
      limit: 1,
      preload: [:actor]
    )
    |> Repo.one()
  end

  defp diff_in_days(nil, _now), do: 0
  defp diff_in_days(%DateTime{} = past, %DateTime{} = now) do
    div(DateTime.diff(now, past, :second), 86_400)
  end

  @doc """
  Renvoie la timeline d'un incident dans l'ordre chronologique. Sécurise
  l'accès : si l'incident est `:council_only` et que le viewer n'est pas
  privilégié, on renvoie `{:error, :not_found}` (et pas `:forbidden`,
  pour ne pas révéler l'existence de l'incident).
  """
  def list_events(incident_id, viewer) do
    incident = Repo.get(Incident, incident_id)

    cond do
      is_nil(incident) ->
        {:error, :not_found}

      incident.visibility == :council_only and
          not privileged?(incident.building_id, viewer) ->
        {:error, :not_found}

      true ->
        events =
          from(e in IncidentEvent,
            where: e.incident_id == ^incident_id,
            order_by: [asc: e.inserted_at],
            preload: [:actor]
          )
          |> Repo.all()

        {:ok, events}
    end
  end

  @doc """
  Relance officielle du syndic sur un dossier. Crée un commentaire
  visible (`is_internal: false`), un IncidentEvent type :follow_up,
  incrémente `follow_up_count`, met à jour `last_follow_up_at` et
  `last_action_at`, broadcast l'incident, push aux privilégiés et
  enqueue un email avec debounce 24h.

  Refuse :
    - si le user n'est pas dans @follow_up_roles (résident simple)
    - si l'incident est résolu / clos / rejeté (pas de zombie-relance)
  """
  def add_follow_up(%Incident{} = incident, %User{} = user, message) do
    cond do
      not follow_up_allowed?(incident.building_id, user) ->
        {:error, :forbidden}

      incident.status in [:resolved, :closed, :rejected] ->
        {:error, :incident_closed}

      true ->
        do_add_follow_up(incident, user, message)
    end
  end

  defp do_add_follow_up(incident, user, message) do
    now = utc_now()

    multi =
      Multi.new()
      |> Multi.insert(:comment, fn _ ->
        IncidentComment.changeset(%IncidentComment{}, %{
          "incident_id" => incident.id,
          "author_id" => user.id,
          "body" => message,
          "is_internal" => false
        })
      end)
      |> Multi.insert(:event, fn %{comment: comment} ->
        IncidentEvent.changeset(%IncidentEvent{}, %{
          incident_id: incident.id,
          actor_id: user.id,
          event_type: :follow_up,
          payload: %{
            "message" => message,
            "comment_id" => to_string(comment.id)
          }
        })
      end)
      |> Multi.update(:incident, fn _ ->
        Incident.changeset(incident, %{
          follow_up_count: (incident.follow_up_count || 0) + 1,
          last_follow_up_at: now,
          last_action_at: now
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{incident: updated, event: event, comment: comment}} ->
        updated = Repo.preload(updated, [:reporter, :assignee])

        BuildingChannel.broadcast_incident(updated.building_id, updated)

        notify_privileged_members(
          updated.building_id,
          "Relance sur un dossier",
          updated.title,
          %{
            type: "incident_follow_up",
            incident_id: updated.id,
            building_id: updated.building_id
          }
        )

        maybe_enqueue_follow_up_email(updated, user, message)

        {:ok, %{incident: updated, event: event, comment: comment}}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # Anti-spam email : si un autre `:follow_up` a déjà été enregistré sur
  # ce dossier dans les 24h précédant celui qu'on vient d'insérer, on
  # n'envoie pas d'email — le syndic a déjà reçu une notification dans
  # la période. La push reste systématique (cf appelant), c'est l'email
  # qu'on debounce.
  defp maybe_enqueue_follow_up_email(%Incident{} = incident, %User{} = user, message) do
    cutoff = DateTime.add(utc_now(), -@follow_up_email_debounce_hours * 3600, :second)

    recent_count =
      from(e in IncidentEvent,
        where: e.incident_id == ^incident.id,
        where: e.event_type == :follow_up,
        where: e.inserted_at > ^cutoff
      )
      |> Repo.aggregate(:count, :id)

    if recent_count <= 1 do
      %{
        "incident_id" => incident.id,
        "follower_id" => user.id,
        "message" => message
      }
      |> SendFollowUpEmailJob.new()
      |> Oban.insert()

      :enqueued
    else
      :skipped
    end
  end

  @doc """
  Lie un incident à une doléance existante. Privilégié-only (syndic,
  conseil syndical, super_admin). Trace `:linked_doleance` dans la
  timeline avec l'id de la doléance.

  La doléance doit appartenir au même bâtiment, sinon `{:error, :building_mismatch}`.
  """
  def link_doleance(%Incident{} = incident, doleance_id, %User{} = actor) do
    cond do
      not privileged?(incident.building_id, actor) ->
        {:error, :forbidden}

      true ->
        do_link_doleance(incident, doleance_id, actor)
    end
  end

  defp do_link_doleance(incident, doleance_id, actor) do
    case Repo.get(Doleance, doleance_id) do
      nil ->
        {:error, :doleance_not_found}

      %Doleance{building_id: bid} when bid != incident.building_id ->
        {:error, :building_mismatch}

      %Doleance{} = doleance ->
        with {:ok, updated} <-
               incident
               |> Incident.changeset(%{
                 linked_doleance_id: doleance.id,
                 last_action_at: utc_now()
               })
               |> Repo.update() do
          record_event(updated, :linked_doleance, actor.id, %{
            "doleance_id" => to_string(doleance.id)
          })

          {:ok, Repo.preload(updated, [:reporter, :assignee, :linked_doleance])}
        end
    end
  end

  def unlink_doleance(%Incident{} = incident, %User{} = actor) do
    cond do
      not privileged?(incident.building_id, actor) ->
        {:error, :forbidden}

      is_nil(incident.linked_doleance_id) ->
        {:ok, incident}

      true ->
        old_id = incident.linked_doleance_id

        with {:ok, updated} <-
               incident
               |> Incident.changeset(%{
                 linked_doleance_id: nil,
                 last_action_at: utc_now()
               })
               |> Repo.update() do
          record_event(updated, :unlinked_doleance, actor.id, %{
            "doleance_id" => to_string(old_id)
          })

          {:ok, Repo.preload(updated, [:reporter, :assignee, :linked_doleance])}
        end
    end
  end

  @doc false
  # Insère un IncidentEvent et met à jour `last_action_at`. Utilisé
  # par tous les use cases qui font évoluer un incident pour alimenter
  # la timeline. Public (`@doc false`) pour permettre les tests
  # unitaires ; ne pas appeler depuis un controller.
  def record_event(%Incident{} = incident, event_type, actor_id, payload) do
    attrs = %{
      incident_id: incident.id,
      actor_id: actor_id,
      event_type: event_type,
      payload: payload || %{}
    }

    case %IncidentEvent{} |> IncidentEvent.changeset(attrs) |> Repo.insert() do
      {:ok, event} ->
        # On évite d'écraser un last_action_at futur (rare mais possible
        # quand on insère un :follow_up explicitement avec son timestamp).
        from(i in Incident,
          where: i.id == ^incident.id,
          where: is_nil(i.last_action_at) or i.last_action_at < ^event.inserted_at,
          update: [set: [last_action_at: ^event.inserted_at]]
        )
        |> Repo.update_all([])

        {:ok, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
