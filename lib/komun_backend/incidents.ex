defmodule KomunBackend.Incidents do
  @moduledoc "Incidents context — scoped by building."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.BuildingMember
  alias KomunBackend.Accounts.User
  alias KomunBackend.Incidents.{Incident, IncidentComment, IncidentFile}
  alias KomunBackend.Notifications
  alias KomunBackendWeb.BuildingChannel

  # Rôles qui peuvent voir les incidents flaggés `:council_only`. On garde
  # la liste alignée avec celle du controller — duplication délibérée pour
  # éviter une dépendance circulaire avec Web.
  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

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
  Liste les incidents signalés par `user_id` sur l'ensemble des
  bâtiments d'une résidence.

  Sert à afficher la fiche détaillée d'un voisin (côté front) à un
  membre du conseil ou au syndic, qui veut voir l'historique de ses
  signalements sur toute la copro — pas seulement sur le bâtiment
  courant du viewer.

  Confidentialité : on **exclut** les incidents `:council_only` quand
  `viewer.id != user_id`, sinon les inclure dans la liste filtrée par
  `reporter_id` revient à dévoiler l'auteur — exactement ce que
  `:council_only` est censé protéger. Pour `viewer.id == user_id` (un
  user qui consulte sa propre activité), on les renvoie : il connaît
  déjà ses propres signalements.

  Brouillons : visibles par les privilégiés et par l'auteur lui-même.
  """
  def list_user_incidents_in_residence(residence_id, user_id, viewer \\ nil) do
    building_ids = KomunBackend.Residences.list_active_building_ids(residence_id)

    if building_ids == [] do
      []
    else
      is_self? = viewer && to_string(viewer.id) == to_string(user_id)

      privileged_in_residence? =
        viewer && KomunBackend.Residences.privileged_member?(residence_id, viewer)

      base =
        from(i in Incident,
          where:
            i.building_id in ^building_ids and
              i.reporter_id == ^user_id,
          preload: [:reporter, :assignee],
          order_by: [desc: i.inserted_at]
        )

      base =
        if is_self? do
          base
        else
          where(base, [i], i.visibility == :standard)
        end

      base =
        if is_self? or privileged_in_residence? do
          base
        else
          where(base, [i], i.status != :brouillon)
        end

      Repo.all(base)
    end
  end

  def list_incidents(building_id, filters \\ %{}, viewer \\ nil) do
    # Inclut les incidents `building_id == ^building_id` ET ceux du
    # niveau résidence (`residence_id == building.residence_id`), pour
    # qu'un résident d'un bâtiment voit aussi les sujets transverses
    # à sa résidence. On branche en fonction du `residence_id` pour
    # éviter `Postgrex 42P18 indeterminate_datatype` quand la valeur
    # est nil (un bâtiment sans résidence — cas legacy).
    residence_id = Buildings.get_residence_id(building_id)

    base =
      from(i in Incident,
        # comment_json/1 reads comment.author, so :author has to be preloaded
        # here too — otherwise we hand it a %Ecto.Association.NotLoaded{} and
        # the whole response crashes with a KeyError on :first_name.
        preload: [:reporter, :assignee, :files, comments: :author],
        order_by: [desc: i.inserted_at]
      )

    base =
      case residence_id do
        nil -> where(base, [i], i.building_id == ^building_id)
        rid -> where(base, [i], i.building_id == ^building_id or i.residence_id == ^rid)
      end

    base
    |> apply_filter(:status, filters["status"])
    |> apply_filter(:severity, filters["severity"])
    |> apply_drafts_visibility(filters, building_id, viewer)
    |> apply_visibility(building_id, viewer)
    |> Repo.all()
  end

  @doc """
  Liste les incidents rattachés au niveau résidence (pas à un bâtiment
  précis). Utilisé par le scope `/residences/:rid/incidents`.
  """
  def list_residence_incidents(residence_id, filters \\ %{}, viewer \\ nil) do
    base =
      from(i in Incident,
        where: i.residence_id == ^residence_id,
        preload: [:reporter, :assignee, :files, comments: :author],
        order_by: [desc: i.inserted_at]
      )

    base
    |> apply_filter(:status, filters["status"])
    |> apply_filter(:severity, filters["severity"])
    |> apply_drafts_visibility_for_residence(filters, residence_id, viewer)
    |> apply_visibility_for_residence(residence_id, viewer)
    |> Repo.all()
  end

  defp apply_filter(q, _field, nil), do: q
  defp apply_filter(q, :status, v), do: where(q, [i], i.status == ^v)
  defp apply_filter(q, :severity, v), do: where(q, [i], i.severity == ^v)

  # Variante "résidence" des helpers de visibilité : un user est
  # considéré comme privilégié pour une résidence s'il a un rôle
  # privilégié dans **au moins un** des bâtiments de la résidence
  # (ou s'il est super_admin global).
  defp privileged_for_residence?(_residence_id, nil), do: false
  defp privileged_for_residence?(_residence_id, %User{role: :super_admin}), do: true

  defp privileged_for_residence?(residence_id, %User{} = user) do
    if user.role in @privileged_roles, do: true, else: residence_member_privileged?(residence_id, user.id)
  end

  # Sous-ensemble qui correspond aux valeurs de l'enum
  # `BuildingMember.role`. `super_admin` / `syndic_*` sont des
  # `User.role` globaux et n'ont pas leur place ici.
  @privileged_member_roles [:president_cs, :membre_cs]

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

  defp apply_drafts_visibility_for_residence(q, _filters, residence_id, viewer) do
    if privileged_for_residence?(residence_id, viewer) do
      q
    else
      where(q, [i], i.status != :brouillon)
    end
  end

  defp apply_visibility_for_residence(q, residence_id, viewer) do
    if privileged_for_residence?(residence_id, viewer) do
      q
    else
      where(q, [i], i.visibility == :standard)
    end
  end

  # Brouillons :
  # - Privilégiés (super_admin / syndic_* / président_cs / membre_cs)
  #   → visibles **par défaut** dans la liste, comme un statut normal.
  #   C'est le seul moyen pour eux de valider les dossiers ingérés.
  # - Résidents lambda → JAMAIS visibles, même si filtre explicite.
  #   Un brouillon est un dossier non validé, il ne doit pas fuiter.
  defp apply_drafts_visibility(q, _filters, building_id, viewer) do
    if privileged?(building_id, viewer) do
      q
    else
      where(q, [i], i.status != :brouillon)
    end
  end

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

  def get_incident!(id),
    do:
      Repo.get!(Incident, id)
      |> Repo.preload([:reporter, :assignee, :files, comments: :author])

  @doc "Same as get_incident!/1 but returns nil when missing."
  def get_incident(id), do: Repo.get(Incident, id)

  def create_incident(building_id, user_id, attrs) do
    attrs = Map.merge(attrs, %{"building_id" => building_id, "reporter_id" => user_id})

    with {:ok, incident} <- %Incident{} |> Incident.changeset(attrs) |> Repo.insert() do
      incident = Repo.preload(incident, [:reporter, :assignee, :files])

      cond do
        # Brouillon : aucun side-effect. Un dossier non validé ne doit
        # ni notifier les voisins, ni consommer du budget Groq, ni
        # apparaître dans le canal temps réel partagé. Validation admin
        # → bascule en :open via update_incident, qui peut alors
        # déclencher les notifs si besoin.
        incident.status == :brouillon ->
          :ok

        incident.visibility == :council_only ->
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

        true ->
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

  @doc """
  Variante "résidence" : crée un incident rattaché à la résidence
  entière (et donc visible à tous les bâtiments). Pas de broadcast
  building-channel (on n'a pas de canal résidence pour l'instant —
  la liste est mise à jour par invalidation côté front à l'ouverture
  de la page). L'IA triage tourne quand même puisqu'elle ne dépend
  pas du building.
  """
  def create_residence_incident(residence_id, user_id, attrs) do
    attrs =
      attrs
      |> Map.delete("building_id")
      |> Map.merge(%{"residence_id" => residence_id, "reporter_id" => user_id})

    with {:ok, incident} <- %Incident{} |> Incident.changeset(attrs) |> Repo.insert() do
      incident = Repo.preload(incident, [:reporter, :assignee, :files])

      if incident.status != :brouillon and incident.visibility == :standard do
        KomunBackend.AI.Triage.triage_incident_async(incident)
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
    council_member_roles = [:president_cs, :membre_cs]
    syndic_user_roles = [:super_admin, :syndic_manager, :syndic_staff]

    users =
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

    Enum.each(users, fn user ->
      Notifications.send_to_user(user, title, body, data)
    end)

    :ok
  end

  @doc """
  Confirms (or re-opens) the AI-generated answer. Only privileged members
  should call this — the controller gates access.
  """
  def confirm_ai_answer(%Incident{} = incident, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    incident
    |> Incident.changeset(%{
      ai_answer_confirmed_at: now,
      ai_answer_confirmed_by_id: user_id
    })
    |> Repo.update()
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
    now = DateTime.utc_now() |> DateTime.truncate(:second)

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
      {:ok, updated}
    end
  end

  def update_incident(incident, attrs) do
    with {:ok, updated} <- incident |> Incident.changeset(attrs) |> Repo.update() do
      updated = Repo.preload(updated, [:reporter, :assignee, :files])
      BuildingChannel.broadcast_incident(updated.building_id, updated)
      {:ok, updated}
    end
  end

  def resolve_incident(incident, note) do
    with {:ok, resolved} <- incident |> Incident.resolve_changeset(note) |> Repo.update() do
      BuildingChannel.broadcast_incident(resolved.building_id, resolved)
      {:ok, resolved}
    end
  end

  # ── Files (uploads) ───────────────────────────────────────────────────────

  @doc """
  Attache une pièce jointe (photo / document) à un incident. La validation
  taille / mime est faite côté controller avant l'appel — ici on ne se
  contente que d'insérer la ligne en DB.
  """
  def attach_file(incident_id, %User{} = user, attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> Map.merge(%{
        "incident_id" => incident_id,
        "uploaded_by_id" => user.id
      })

    %IncidentFile{}
    |> IncidentFile.changeset(attrs)
    |> Repo.insert()
  end

  def get_file!(id), do: Repo.get!(IncidentFile, id)

  def delete_file(%IncidentFile{} = file), do: Repo.delete(file)

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  def add_comment(incident_id, author_id, attrs) do
    attrs = Map.merge(attrs, %{"incident_id" => incident_id, "author_id" => author_id})

    with {:ok, comment} <- %IncidentComment{} |> IncidentComment.changeset(attrs) |> Repo.insert() do
      # `is_internal: true` = note privée du syndic / import historique
      # (skill `komun-ingest`, ingestion email Resend) → on ne pousse pas
      # de notification aux résidents : ils ont déjà reçu ces messages
      # hors plateforme. Sans ce gating, importer 30 emails archivés
      # déclencherait 30 pushes inutiles.
      unless comment.is_internal do
        incident = get_incident!(incident_id)

        Notifications.send_to_building(
          incident.building_id,
          "Nouvelle réponse à un incident",
          incident.title,
          %{type: "incident_comment", incident_id: incident_id, building_id: incident.building_id}
        )
      end

      {:ok, comment}
    end
  end
end
