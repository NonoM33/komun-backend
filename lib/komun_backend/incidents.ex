defmodule KomunBackend.Incidents do
  @moduledoc "Incidents context — scoped by building."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.BuildingMember
  alias KomunBackend.Accounts.User
  alias KomunBackend.Incidents.{Incident, IncidentComment}
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
    attrs = Map.merge(attrs, %{"building_id" => building_id, "reporter_id" => user_id})

    with {:ok, incident} <- %Incident{} |> Incident.changeset(attrs) |> Repo.insert() do
      incident = Repo.preload(incident, [:reporter, :assignee])

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

        # Génère aussi un micro_summary (1 phrase pour la vue liste).
        # On ne touche ni au titre ni à la description ici — le résident
        # vient de les écrire, on respecte ses mots. Mode `:all` est
        # déclenché plus tard si l'incident reçoit des emails (cf.
        # webhook + endpoint regenerate_summary).
        KomunBackend.AI.IncidentSummarizer.summarize_async(incident, mode: :micro_only)
      end

      {:ok, incident}
    end
  end

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
      updated = Repo.preload(updated, [:reporter, :assignee])
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

  def add_comment(incident_id, author_id, attrs) do
    attrs = Map.merge(attrs, %{"incident_id" => incident_id, "author_id" => author_id})

    with {:ok, comment} <- %IncidentComment{} |> IncidentComment.changeset(attrs) |> Repo.insert() do
      incident = get_incident!(incident_id)

      Notifications.send_to_building(
        incident.building_id,
        "Nouvelle réponse à un incident",
        incident.title,
        %{type: "incident_comment", incident_id: incident_id, building_id: incident.building_id}
      )

      # Si le commentaire vient d'un email importé/webhook (préfixe 📧),
      # on relance le summarizer en mode :all : la chronologie a évolué,
      # le micro_summary et la description doivent suivre. Pour un
      # commentaire libre tapé par un résident, on ne change rien.
      if is_binary(comment.body) and String.starts_with?(comment.body, "📧") do
        KomunBackend.AI.IncidentSummarizer.summarize_async(incident, mode: :all)
      end

      {:ok, comment}
    end
  end

  @doc """
  Liste les incidents ouverts (status :open ou :in_progress) d'un bâtiment.
  Utilisé par le router AI pour décider si un email entrant continue un
  dossier existant ou en démarre un nouveau.
  """
  def list_open_incidents(building_id) do
    import Ecto.Query

    Repo.all(
      from i in Incident,
        where: i.building_id == ^building_id and i.status in [:open, :in_progress],
        order_by: [desc: i.inserted_at]
    )
  end
end
