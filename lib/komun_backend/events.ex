defmodule KomunBackend.Events do
  @moduledoc """
  Events context — fête des voisins, ateliers, AG, réunions de conseil.

  Un event est rattaché à une **résidence**. Il peut être restreint à
  certains bâtiments via `event_building_scopes` (sinon visible à toute
  la résidence). Création réservée aux rôles privilégiés (super_admin /
  syndic / conseil syndical) ; tout membre actif peut RSVP / claim une
  contribution / commenter.
  """

  import Ecto.Query
  alias Ecto.Multi

  alias KomunBackend.Repo
  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.BuildingMember
  alias KomunBackend.Accounts.User

  alias KomunBackend.Events.{
    Event,
    EventBuildingScope,
    EventOrganizer,
    EventParticipation,
    EventContribution,
    EventContributionClaim,
    EventComment,
    EventEmailBlast
  }

  alias KomunBackend.Notifications.Jobs.{
    EventReminderJob,
    EventContributionGapJob,
    EventThankYouJob
  }

  alias KomunBackendWeb.BuildingChannel

  # Mêmes rôles privilégiés que pour les incidents — duplication
  # délibérée pour rester découplé de Incidents (cf. commentaire dans
  # `Incidents.@privileged_roles`).
  @privileged_user_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]
  @privileged_member_roles [:president_cs, :membre_cs]

  @event_preloads [
    :creator,
    :residence,
    organizers: :user,
    building_scopes: :building,
    participations: :user,
    contributions: [:created_by, claims: :user],
    comments: :author,
    email_blasts: :triggered_by
  ]

  # Limite hard côté backend : 1 blast manuel par heure et par event.
  @blast_rate_limit_seconds 3_600

  # ── Permissions ──────────────────────────────────────────────────────────

  @doc """
  `true` si `user` peut créer / éditer / annuler un event sur la résidence
  donnée. Calque la règle produit : super_admin + syndic + conseil
  syndical (membre du CS dans n'importe quel bâtiment de la résidence).
  """
  def can_create_event?(_residence_id, nil), do: false
  def can_create_event?(_residence_id, %User{role: :super_admin}), do: true

  def can_create_event?(residence_id, %User{} = user) do
    cond do
      user.role in @privileged_user_roles -> true
      true -> residence_member_privileged?(residence_id, user.id)
    end
  end

  defp residence_member_privileged?(residence_id, user_id) do
    from(bm in BuildingMember,
      join: b in assoc(bm, :building),
      where:
        b.residence_id == ^residence_id and bm.user_id == ^user_id and
          bm.role in ^@privileged_member_roles,
      select: 1,
      limit: 1
    )
    |> Repo.one()
    |> Kernel.!=(nil)
  end

  @doc """
  `true` si `user` est créateur ou co-organisateur de l'event, OU s'il a
  un rôle privilégié global. Les co-orga peuvent éditer l'event,
  déclencher un email blast, annuler.
  """
  def can_organize?(_event_id, nil), do: false
  def can_organize?(_event_id, %User{role: :super_admin}), do: true

  def can_organize?(event_id, %User{} = user) do
    cond do
      user.role in @privileged_user_roles ->
        true

      organizer?(event_id, user.id) ->
        true

      true ->
        false
    end
  end

  defp organizer?(event_id, user_id) do
    from(o in EventOrganizer,
      where: o.event_id == ^event_id and o.user_id == ^user_id,
      select: 1,
      limit: 1
    )
    |> Repo.one()
    |> Kernel.!=(nil)
  end

  # ── Lecture ──────────────────────────────────────────────────────────────

  @doc """
  Liste les events visibles depuis le bâtiment donné. Inclut :
    1. Les events SANS scope (pas de ligne dans event_building_scopes)
       → visibles à toute la résidence du bâtiment.
    2. Les events explicitement scopés au bâtiment.
  Filtre `:upcoming` (true → starts_at > now) ou `:past` (true → ends_at <= now).
  Les drafts ne sortent jamais ici, sauf au créateur / organisateurs / privilégiés.
  """
  def list_events_for_building(building_id, filters \\ %{}, viewer \\ nil) do
    residence_id = Buildings.get_residence_id(building_id)

    if is_nil(residence_id) do
      # Bâtiment sans résidence (cas legacy) — pas d'events.
      []
    else
      base_query(residence_id, building_id)
      |> apply_time_filter(filters)
      |> apply_status_visibility(viewer, residence_id)
      |> Repo.all()
      |> Repo.preload(@event_preloads)
    end
  end

  defp base_query(residence_id, building_id) do
    # Events visibles depuis ce building =
    #   events de la résidence ET (pas de scope OU scope contient ce building)
    from(e in Event,
      left_join: s in EventBuildingScope,
      on: s.event_id == e.id,
      where: e.residence_id == ^residence_id,
      group_by: e.id,
      having:
        count(s.event_id) == 0 or
          fragment("? = ANY(array_agg(?))", type(^building_id, :binary_id), s.building_id),
      order_by: [asc: e.starts_at]
    )
  end

  defp apply_time_filter(q, %{"upcoming" => v}) when v in [true, "true"],
    do: where(q, [e], e.ends_at >= ^DateTime.utc_now())

  defp apply_time_filter(q, %{"past" => v}) when v in [true, "true"],
    do: where(q, [e], e.ends_at < ^DateTime.utc_now())

  defp apply_time_filter(q, _), do: q

  # Brouillons : visibles uniquement aux organisateurs ou aux rôles privilégiés
  # globaux. Pour un voisin lambda → on cache.
  defp apply_status_visibility(q, viewer, residence_id) do
    cond do
      is_nil(viewer) ->
        where(q, [e], e.status != :draft)

      viewer.role == :super_admin ->
        q

      viewer.role in @privileged_user_roles ->
        q

      residence_member_privileged?(residence_id, viewer.id) ->
        q

      true ->
        where(q, [e], e.status != :draft)
    end
  end

  @doc "Récupère un event avec toutes ses relations préchargées (raise si absent)."
  def get_event!(id) do
    Event
    |> Repo.get!(id)
    |> Repo.preload(@event_preloads)
  end

  def get_event(id) do
    case Repo.get(Event, id) do
      nil -> nil
      ev -> Repo.preload(ev, @event_preloads)
    end
  end

  # ── Création ─────────────────────────────────────────────────────────────

  @doc """
  Crée un event sous une résidence. `attrs` contient les champs Event
  classiques + `building_ids` (liste optionnelle d'UUIDs de bâtiments
  pour restreindre la visibilité). `building_ids` vide ou absent = event
  visible à toute la résidence.

  Le créateur est automatiquement inscrit comme `:creator` dans
  `event_organizers` — un seul `Multi` pour rester atomique.
  """
  def create_event(residence_id, %User{} = user, attrs) do
    building_ids = extract_building_ids(attrs)

    base_attrs =
      attrs
      |> drop_keys(["building_ids", :building_ids])
      |> Map.put("residence_id", residence_id)
      |> Map.put("creator_id", user.id)

    Multi.new()
    |> Multi.insert(:event, Event.changeset(%Event{}, base_attrs))
    |> Multi.insert(:creator_organizer, fn %{event: event} ->
      EventOrganizer.changeset(%EventOrganizer{}, %{
        "event_id" => event.id,
        "user_id" => user.id,
        "role" => :creator
      })
    end)
    |> insert_scopes(building_ids)
    |> Repo.transaction()
    |> case do
      {:ok, %{event: event}} ->
        full = get_event!(event.id)
        full = maybe_schedule_jobs(full)
        broadcast_event_to_scope(full, :created)
        {:ok, full}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # ── Programmation des jobs Oban ─────────────────────────────────────────
  #
  # On programme à la création / publication :
  #   - reminder_j1 : 24h avant `starts_at` (push + email aux RSVP)
  #   - gap_j3 : 72h avant `starts_at` (push smart « il manque X »)
  #   - thank_you_j_plus_1 : 24h après `ends_at` (email merci)
  #
  # Si l'event est en draft, on attend la publication. Si l'event est
  # créé moins de 24h avant son début, le reminder ne tournera tout
  # simplement pas (Oban skip les jobs scheduled_at dans le passé).
  defp maybe_schedule_jobs(%Event{status: :draft} = event), do: event

  defp maybe_schedule_jobs(%Event{} = event) do
    reminder_at = DateTime.add(event.starts_at, -24 * 3600, :second)
    gap_at = DateTime.add(event.starts_at, -72 * 3600, :second)
    thank_at = DateTime.add(event.ends_at, 24 * 3600, :second)

    reminder_id = enqueue_event_job(EventReminderJob, event.id, reminder_at)
    gap_id = enqueue_event_job(EventContributionGapJob, event.id, gap_at)
    thank_id = enqueue_event_job(EventThankYouJob, event.id, thank_at)

    case event
         |> Event.changeset(%{
           reminder_job_id: reminder_id,
           gap_job_id: gap_id,
           thank_you_job_id: thank_id
         })
         |> Repo.update() do
      {:ok, updated} -> Repo.preload(updated, @event_preloads, force: true)
      _ -> event
    end
  end

  defp enqueue_event_job(worker, event_id, %DateTime{} = scheduled_at) do
    case worker.new(%{event_id: event_id}, scheduled_at: scheduled_at) |> Oban.insert() do
      {:ok, %Oban.Job{id: id}} -> id
      _ -> nil
    end
  end

  # ── Email blast manuel ──────────────────────────────────────────────────
  #
  # L'organisateur déclenche un envoi à TOUS les membres du scope (pas
  # seulement les RSVP — le but est d'inviter ceux qui n'ont pas encore
  # vu l'event). Rate-limité à 1/heure côté backend (défense contre un
  # double-clic ou un script abusif), avec confirmation forte côté front.
  def send_email_blast(event_id, %User{} = user, opts \\ []) do
    ip = Keyword.get(opts, :ip)
    custom_subject = Keyword.get(opts, :subject)
    custom_body = Keyword.get(opts, :body)

    with {:ok, event} <- fetch_event_for_blast(event_id),
         :ok <- check_rate_limit(event_id),
         :ok <- check_can_blast(event.id, user) do
      do_send_blast(event, user, ip, custom_subject, custom_body)
    end
  end

  defp fetch_event_for_blast(event_id) do
    case get_event(event_id) do
      nil -> {:error, :not_found}
      %Event{status: :cancelled} -> {:error, :event_cancelled}
      %Event{status: :draft} -> {:error, :event_draft}
      event -> {:ok, event}
    end
  end

  defp check_rate_limit(event_id) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@blast_rate_limit_seconds, :second)

    recent? =
      from(b in EventEmailBlast,
        where:
          b.event_id == ^event_id and b.kind == ^:manual_invite and b.sent_at >= ^cutoff,
        limit: 1
      )
      |> Repo.exists?()

    if recent?, do: {:error, :rate_limited}, else: :ok
  end

  defp check_can_blast(event_id, user) do
    if can_organize?(event_id, user), do: :ok, else: {:error, :forbidden}
  end

  defp do_send_blast(event, user, ip, custom_subject, custom_body) do
    recipient_user_ids = blast_recipient_user_ids(event)

    users =
      from(u in KomunBackend.Accounts.User, where: u.id in ^recipient_user_ids)
      |> Repo.all()

    Enum.each(users, fn u -> send_blast_email(event, u, custom_body) end)

    %EventEmailBlast{}
    |> EventEmailBlast.changeset(%{
      event_id: event.id,
      triggered_by_id: user.id,
      kind: :manual_invite,
      recipient_count: length(users),
      subject: custom_subject || "Vous êtes invité : #{event.title}",
      body_preview: blast_body_preview(custom_body, event),
      triggered_ip: ip
    })
    |> Repo.insert()
  end

  defp blast_body_preview(body, _event) when is_binary(body) and body != "" do
    String.slice(body, 0, 280)
  end

  defp blast_body_preview(_, %Event{description: desc}) when is_binary(desc) do
    String.slice(desc, 0, 280)
  end

  defp blast_body_preview(_, _), do: nil

  defp blast_recipient_user_ids(%Event{} = event) do
    full = if event.building_scopes == [] or match?(%Ecto.Association.NotLoaded{}, event.building_scopes),
                                                    do: get_event!(event.id), else: event

    scope_buildings =
      case full.building_scopes do
        [] ->
          from(b in KomunBackend.Buildings.Building,
            where: b.residence_id == ^full.residence_id,
            select: b.id
          )
          |> Repo.all()

        list ->
          Enum.map(list, & &1.building_id)
      end

    member_pairs =
      from(m in KomunBackend.Buildings.BuildingMember,
        join: u in KomunBackend.Accounts.User,
        on: u.id == m.user_id,
        where: m.building_id in ^scope_buildings and m.is_active == true,
        select: {u, m.role},
        distinct: true
      )
      |> Repo.all()

    case full.target_resident_types do
      nil ->
        Enum.map(member_pairs, fn {u, _r} -> u.id end) |> Enum.uniq()

      [] ->
        Enum.map(member_pairs, fn {u, _r} -> u.id end) |> Enum.uniq()

      target_types when is_list(target_types) ->
        member_pairs
        |> Enum.filter(fn {u, role} ->
          buckets = Event.resident_buckets(u, role)
          Enum.any?(buckets, &(&1 in target_types))
        end)
        |> Enum.map(fn {u, _r} -> u.id end)
        |> Enum.uniq()
    end
  end

  defp send_blast_email(event, user, custom_body) do
    alias KomunBackend.Mailer
    alias Swoosh.Email

    body =
      case custom_body do
        nil -> event.description || ""
        b when is_binary(b) -> b
      end

    Email.new()
    |> Email.to(user.email)
    |> Email.from({"Komun", "noreply@komun.app"})
    |> Email.subject("Vous êtes invité : #{event.title}")
    |> Email.html_body(blast_html(event, body))
    |> Email.text_body(blast_text(event, body))
    |> Mailer.deliver()

    :ok
  rescue
    _ -> :ok
  end

  defp blast_html(event, body) do
    alias KomunBackend.Notifications.EmailLayout

    EmailLayout.render(
      preheader: "Un événement de voisinage vous attend.",
      body:
        EmailLayout.h1(EmailLayout.escape(event.title)) <>
          EmailLayout.p(format_when_html(event)) <>
          (if event.location_label,
             do: EmailLayout.p("📍 " <> EmailLayout.escape(event.location_label)),
             else: "") <>
          (if body != "", do: EmailLayout.p(EmailLayout.escape(body)), else: "") <>
          EmailLayout.cta_button(
            "https://komun.app/events/#{event.id}",
            "Je participe ou je décline"
          ) <>
          EmailLayout.muted(
            "Cet email a été envoyé par un organisateur de votre résidence via Komun."
          )
    )
  end

  defp blast_text(event, body) do
    """
    Vous êtes invité : #{event.title}

    #{format_when_text(event)}#{if event.location_label, do: "\nLieu : " <> event.location_label, else: ""}

    #{body}

    Voir l'événement : https://komun.app/events/#{event.id}
    """
  end

  defp format_when_html(event), do: format_when_text(event)

  defp format_when_text(%Event{starts_at: s}) do
    "📅 " <> Calendar.strftime(s, "%d/%m/%Y à %H:%M")
  end

  defp insert_scopes(multi, []), do: multi

  defp insert_scopes(multi, building_ids) when is_list(building_ids) do
    Enum.reduce(building_ids, multi, fn bid, m ->
      Multi.insert(m, {:scope, bid}, fn %{event: event} ->
        EventBuildingScope.changeset(%EventBuildingScope{}, %{
          "event_id" => event.id,
          "building_id" => bid
        })
      end)
    end)
  end

  defp extract_building_ids(attrs) do
    val = Map.get(attrs, "building_ids") || Map.get(attrs, :building_ids) || []
    Enum.filter(val, &is_binary/1)
  end

  defp drop_keys(map, keys), do: Map.drop(map, keys)

  # ── Mise à jour ──────────────────────────────────────────────────────────

  @doc """
  Met à jour un event. Si `building_ids` est dans `attrs`, le scope est
  intégralement remplacé (delete + insert) — sémantique « set », plus
  simple côté front qu'un diff.
  """
  def update_event(%Event{} = event, attrs) do
    has_scope_update? = Map.has_key?(attrs, "building_ids") or Map.has_key?(attrs, :building_ids)
    new_building_ids = extract_building_ids(attrs)

    base_attrs = drop_keys(attrs, ["building_ids", :building_ids])

    Multi.new()
    |> Multi.update(:event, Event.changeset(event, base_attrs))
    |> maybe_replace_scopes(event.id, has_scope_update?, new_building_ids)
    |> Repo.transaction()
    |> case do
      {:ok, %{event: updated}} ->
        full = get_event!(updated.id)
        broadcast_event_to_scope(full, :updated)
        {:ok, full}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp maybe_replace_scopes(multi, _event_id, false, _ids), do: multi

  defp maybe_replace_scopes(multi, event_id, true, new_ids) do
    multi
    |> Multi.delete_all(:delete_scopes, from(s in EventBuildingScope, where: s.event_id == ^event_id))
    |> insert_scopes(new_ids)
  end

  @doc "Annule un event (soft-cancel)."
  def cancel_event(%Event{} = event, reason) when is_binary(reason) do
    case event |> Event.cancel_changeset(reason) |> Repo.update() do
      {:ok, updated} ->
        full = get_event!(updated.id)
        broadcast_event_to_scope(full, :cancelled)
        {:ok, full}

      {:error, cs} ->
        {:error, cs}
    end
  end

  # ── RSVP / Participations ────────────────────────────────────────────────

  @doc """
  Crée ou met à jour la participation d'un user (upsert sur (event, user)).
  """
  def upsert_participation(event_id, user_id, attrs) do
    attrs =
      attrs
      |> Map.put("event_id", event_id)
      |> Map.put("user_id", user_id)

    case Repo.get_by(EventParticipation, event_id: event_id, user_id: user_id) do
      nil -> %EventParticipation{}
      existing -> existing
    end
    |> EventParticipation.changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, participation} ->
        broadcast_participation(event_id, participation)
        {:ok, Repo.preload(participation, :user)}

      err ->
        err
    end
  end

  def delete_participation(event_id, user_id) do
    case Repo.get_by(EventParticipation, event_id: event_id, user_id: user_id) do
      nil ->
        {:ok, :noop}

      p ->
        case Repo.delete(p) do
          {:ok, _} ->
            broadcast_participation_removed(event_id, user_id)
            {:ok, :deleted}

          err ->
            err
        end
    end
  end

  # ── Contributions ────────────────────────────────────────────────────────

  def create_contribution(event_id, user_id, attrs) do
    attrs =
      attrs
      |> Map.put("event_id", event_id)
      |> Map.put("created_by_id", user_id)

    %EventContribution{}
    |> EventContribution.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, contribution} ->
        broadcast_contribution(event_id)
        {:ok, Repo.preload(contribution, [:created_by, claims: :user])}

      err ->
        err
    end
  end

  def update_contribution(%EventContribution{} = contribution, attrs) do
    contribution
    |> EventContribution.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        broadcast_contribution(updated.event_id)
        {:ok, Repo.preload(updated, [:created_by, claims: :user])}

      err ->
        err
    end
  end

  def delete_contribution(%EventContribution{} = contribution) do
    case Repo.delete(contribution) do
      {:ok, deleted} ->
        broadcast_contribution(deleted.event_id)
        {:ok, deleted}

      err ->
        err
    end
  end

  def get_contribution!(id), do: Repo.get!(EventContribution, id)
  def get_claim!(id), do: Repo.get!(EventContributionClaim, id)

  @doc """
  Crée un NOUVEAU claim. Plusieurs claims par (user, contribution) sont
  permis : un voisin peut dire « 1 coca zero » puis « 1 coca cherry »
  sous la même rubrique « Soft » — chacun sa ligne avec son libellé.
  """
  def add_claim(contribution_id, user_id, attrs) do
    attrs =
      attrs
      |> Map.put("contribution_id", contribution_id)
      |> Map.put("user_id", user_id)

    %EventContributionClaim{}
    |> EventContributionClaim.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, claim} ->
        contribution = Repo.get!(EventContribution, contribution_id)
        broadcast_contribution(contribution.event_id)
        {:ok, Repo.preload(claim, :user)}

      err ->
        err
    end
  end

  @doc "Met à jour un claim donné par son id (qty / commentaire)."
  def update_claim_by_id(claim_id, attrs) do
    claim = Repo.get!(EventContributionClaim, claim_id)

    claim
    |> EventContributionClaim.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        contribution = Repo.get!(EventContribution, updated.contribution_id)
        broadcast_contribution(contribution.event_id)
        {:ok, Repo.preload(updated, :user)}

      err ->
        err
    end
  end

  @doc "Supprime un claim donné par son id."
  def delete_claim_by_id(claim_id) do
    case Repo.get(EventContributionClaim, claim_id) do
      nil ->
        {:ok, :noop}

      claim ->
        case Repo.delete(claim) do
          {:ok, deleted} ->
            contribution = Repo.get!(EventContribution, deleted.contribution_id)
            broadcast_contribution(contribution.event_id)
            {:ok, :deleted}

          err ->
            err
        end
    end
  end

  # Variantes legacy : delete_claim par (contribution, user) — supprime
  # TOUS les claims de ce user sur cette rubrique. Conservée pour la
  # compat avec l'ancien endpoint REST `DELETE …/contributions/:id/claim`
  # — un mobile / script qui pointe encore là continuera à fonctionner.
  def delete_claim(contribution_id, user_id) do
    deleted_count =
      from(c in EventContributionClaim,
        where: c.contribution_id == ^contribution_id and c.user_id == ^user_id
      )
      |> Repo.delete_all()
      |> elem(0)

    if deleted_count > 0 do
      contribution = Repo.get!(EventContribution, contribution_id)
      broadcast_contribution(contribution.event_id)
      {:ok, :deleted}
    else
      {:ok, :noop}
    end
  end

  @doc """
  Réorganise les rubriques d'un event. Donne la liste ordonnée des
  contribution_ids — la position de chaque rubrique est mise à jour
  pour matcher l'ordre fourni. Les ids hors event ou inexistants sont
  ignorés silencieusement.
  """
  def reorder_contributions(event_id, ordered_ids) when is_list(ordered_ids) do
    Repo.transaction(fn ->
      ordered_ids
      |> Enum.with_index()
      |> Enum.each(fn {cid, idx} ->
        from(c in EventContribution,
          where: c.id == ^cid and c.event_id == ^event_id
        )
        |> Repo.update_all(set: [position: idx, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])
      end)
    end)
    |> case do
      {:ok, _} ->
        broadcast_contribution(event_id)
        {:ok, get_event!(event_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  HARD-delete d'un event : retire la ligne de la base, cascadant sur
  toutes les tables filles. **Réservé aux super_admin / syndic_manager**
  — gating à faire côté controller, ce contexte ne fait que la
  mécanique. À utiliser quand `cancel_event` (soft-cancel) ne suffit
  pas — par exemple un event créé par erreur, doublon, etc.
  """
  def purge_event(%Event{} = event) do
    case Repo.delete(event) do
      {:ok, deleted} ->
        # Best-effort broadcast — les bâtiments du scope étant déjà
        # cascade-deleted, on prend les ids avant.
        Enum.each(event_target_building_ids(event), fn bid ->
          BuildingChannel.broadcast_event(bid, deleted, :cancelled)
        end)

        {:ok, deleted}

      err ->
        err
    end
  end

  # ── Commentaires ─────────────────────────────────────────────────────────

  def add_comment(event_id, author_id, attrs) do
    attrs =
      attrs
      |> Map.put("event_id", event_id)
      |> Map.put("author_id", author_id)

    %EventComment{}
    |> EventComment.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, comment} ->
        full = Repo.preload(comment, :author)
        broadcast_comment(event_id, full)
        {:ok, full}

      err ->
        err
    end
  end

  def delete_comment(%EventComment{} = comment) do
    case Repo.delete(comment) do
      {:ok, deleted} ->
        broadcast_comment_removed(deleted.event_id, deleted.id)
        {:ok, deleted}

      err ->
        err
    end
  end

  def get_comment!(id), do: Repo.get!(EventComment, id)

  @doc """
  Toggle d'une réaction emoji sur un commentaire. Si l'utilisateur a
  déjà réagi avec ce même emoji, retire ; sinon ajoute. Stockage en
  jsonb : %{"❤️" => %{"count" => N, "user_ids" => [uuid…]}}.
  """
  def toggle_reaction(%EventComment{} = comment, emoji, user_id) when is_binary(emoji) do
    user_str = to_string(user_id)
    reactions = comment.reactions || %{}
    current = Map.get(reactions, emoji, %{"count" => 0, "user_ids" => []})
    user_ids = Map.get(current, "user_ids", [])

    new_reactions =
      if user_str in user_ids do
        remaining = Enum.reject(user_ids, &(&1 == user_str))

        if remaining == [] do
          Map.delete(reactions, emoji)
        else
          Map.put(reactions, emoji, %{
            "count" => length(remaining),
            "user_ids" => remaining
          })
        end
      else
        new_user_ids = [user_str | user_ids]

        Map.put(reactions, emoji, %{
          "count" => length(new_user_ids),
          "user_ids" => new_user_ids
        })
      end

    comment
    |> EventComment.changeset(%{reactions: new_reactions})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        full = Repo.preload(updated, :author)
        broadcast_comment(updated.event_id, full)
        {:ok, full}

      err ->
        err
    end
  end

  # ── Broadcasts ───────────────────────────────────────────────────────────

  # Pour un event de niveau résidence (pas de scope), on broadcast sur
  # CHAQUE bâtiment de la résidence — chaque membre est dans le canal de
  # son propre bâtiment, pas dans un canal résidence (cf. front
  # WebSocket existant). Pour un event scopé, on broadcast uniquement
  # aux bâtiments du scope.
  defp broadcast_event_to_scope(%Event{} = event, action) do
    target_buildings = event_target_building_ids(event)

    Enum.each(target_buildings, fn bid ->
      BuildingChannel.broadcast_event(bid, event, action)
    end)
  end

  defp event_target_building_ids(%Event{} = event) do
    case event.building_scopes do
      %Ecto.Association.NotLoaded{} ->
        residence_building_ids(event.residence_id)

      [] ->
        residence_building_ids(event.residence_id)

      scopes ->
        Enum.map(scopes, & &1.building_id)
    end
  end

  defp residence_building_ids(residence_id) do
    from(b in KomunBackend.Buildings.Building,
      where: b.residence_id == ^residence_id,
      select: b.id
    )
    |> Repo.all()
  end

  defp broadcast_participation(event_id, participation) do
    case Repo.get(Event, event_id) do
      nil -> :ok
      event -> Enum.each(event_target_building_ids(Repo.preload(event, :building_scopes)),
                         &BuildingChannel.broadcast_event_participation(&1, event_id, participation))
    end
  end

  defp broadcast_participation_removed(event_id, user_id) do
    case Repo.get(Event, event_id) do
      nil ->
        :ok

      event ->
        Enum.each(
          event_target_building_ids(Repo.preload(event, :building_scopes)),
          &BuildingChannel.broadcast_event_participation_removed(&1, event_id, user_id)
        )
    end
  end

  defp broadcast_contribution(event_id) do
    case Repo.get(Event, event_id) do
      nil ->
        :ok

      _event ->
        full = get_event!(event_id)

        Enum.each(
          event_target_building_ids(full),
          &BuildingChannel.broadcast_event_contributions(&1, event_id, full.contributions)
        )
    end
  end

  defp broadcast_comment(event_id, comment) do
    case Repo.get(Event, event_id) do
      nil ->
        :ok

      event ->
        Enum.each(
          event_target_building_ids(Repo.preload(event, :building_scopes)),
          &BuildingChannel.broadcast_event_comment(&1, event_id, comment)
        )
    end
  end

  defp broadcast_comment_removed(event_id, comment_id) do
    case Repo.get(Event, event_id) do
      nil ->
        :ok

      event ->
        Enum.each(
          event_target_building_ids(Repo.preload(event, :building_scopes)),
          &BuildingChannel.broadcast_event_comment_removed(&1, event_id, comment_id)
        )
    end
  end
end
