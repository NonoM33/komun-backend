defmodule KomunBackendWeb.IncidentController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Incidents}
  alias KomunBackend.Auth.Guardian

  # GET /api/v1/buildings/:building_id/incidents
  def index(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      privileged? = Incidents.privileged?(building_id, user)
      incidents = Incidents.list_incidents(building_id, params, user)

      json(conn, %{
        data: Enum.map(incidents, &incident_json(&1, privileged?, user.id))
      })
    end
  end

  # GET /api/v1/buildings/:building_id/incidents/:id
  def show(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      incident = Incidents.get_incident!(id)
      privileged? = Incidents.privileged?(building_id, user)

      cond do
        # Sécurité défensive : un incident `:council_only` ne doit jamais
        # être servi à un non-privilégié — sauf au créateur lui-même, qui
        # garde la main sur son propre signalement (suivi de la résolution
        # depuis la liste / l'URL directe).
        incident.visibility == :council_only and not privileged? and
            incident.reporter_id != user.id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          json(conn, %{data: incident_json(incident, privileged?, user.id)})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/incidents
  def create(conn, %{"building_id" => building_id, "incident" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         {:ok, incident} <- Incidents.create_incident(building_id, user.id, attrs) do
      privileged? = Incidents.privileged?(building_id, user)

      conn
      |> put_status(:created)
      |> json(%{data: incident_json(incident, privileged?, user.id)})
    else
      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  # PUT /api/v1/buildings/:building_id/incidents/:id
  def update(conn, %{"building_id" => building_id, "id" => id, "incident" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      incident = Incidents.get_incident!(id)
      privileged? = Incidents.privileged?(building_id, user)

      cond do
        # L'écriture sur un `:council_only` reste réservée au conseil — le
        # créateur peut LIRE son propre signalement (cf. `show`) mais pas
        # le modifier (statut, note de résolution, etc. = rôle du CS).
        incident.visibility == :council_only and not privileged? ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          case Incidents.update_incident(incident, attrs) do
            {:ok, updated} -> json(conn, %{data: incident_json(updated, privileged?, user.id)})
            {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
          end
      end
    end
  end

  # DELETE /api/v1/buildings/:building_id/incidents/:id
  def delete(conn, %{"building_id" => building_id, "id" => id}) do
    with :ok <- authorize_building(conn, building_id) do
      incident = Incidents.get_incident!(id)
      KomunBackend.Repo.delete!(incident)
      send_resp(conn, :no_content, "")
    end
  end

  # POST /api/v1/buildings/:building_id/incidents/:incident_id/confirm-ai
  # Restricted to privileged members (syndic + conseil + super_admin).
  #
  # NB : Phoenix nomme le path param `:incident_id` (et non `:id`) pour
  # les routes member définies à l'intérieur d'un bloc `resources do …
  # end`. Sans ça la fonction ne matche pas quand le client envoie un
  # body vide → 400 silencieux côté UI (cf. fix 2026-04-25).
  def confirm_ai_answer(conn, %{"building_id" => building_id, "incident_id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      incident = Incidents.get_incident!(id)

      case Incidents.confirm_ai_answer(incident, user.id) do
        {:ok, updated} ->
          updated = KomunBackend.Repo.preload(updated, [:reporter, :assignee, comments: :author])
          json(conn, %{data: incident_json(updated, true, user.id)})

        {:error, cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
      end
    end
  end

  # DELETE /api/v1/buildings/:building_id/incidents/:incident_id/confirm-ai
  def unconfirm_ai_answer(conn, %{"building_id" => building_id, "incident_id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      incident = Incidents.get_incident!(id)

      case Incidents.unconfirm_ai_answer(incident) do
        {:ok, updated} ->
          updated = KomunBackend.Repo.preload(updated, [:reporter, :assignee, comments: :author])
          json(conn, %{data: incident_json(updated, true, user.id)})

        {:error, cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
      end
    end
  end

  # PUT /api/v1/buildings/:building_id/incidents/:incident_id/ai-answer
  #
  # Edit the AI answer text (and optionally validate it in one shot by
  # passing `confirm: true`). Privileged members only — residents see the
  # saved version, confirmed or not, from the list endpoint.
  def update_ai_answer(conn, %{"building_id" => building_id, "incident_id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    ai_answer = Map.get(params, "ai_answer", "")
    confirm? = params["confirm"] == true

    with :ok <- authorize_privileged(conn, building_id, user) do
      incident = Incidents.get_incident!(id)

      case Incidents.update_ai_answer(incident, ai_answer, user.id, confirm: confirm?) do
        {:ok, updated} ->
          updated = KomunBackend.Repo.preload(updated, [:reporter, :assignee, comments: :author])
          json(conn, %{data: incident_json(updated, true, user.id)})

        {:error, cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
      end
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  defp authorize_privileged(conn, building_id, user) do
    member_role = Buildings.get_member_role(building_id, user.id)

    cond do
      user.role == :super_admin -> :ok
      user.role in @privileged_roles -> :ok
      member_role in @privileged_roles -> :ok
      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Seuls le syndic et le conseil syndical peuvent valider une réponse IA."})
        |> halt()
    end
  end

  defp authorize_building(conn, building_id) do
    user = Guardian.Plug.current_resource(conn)
    if user.role == :super_admin or Buildings.member?(building_id, user.id) do
      :ok
    else
      conn |> put_status(403) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp incident_json(inc, privileged?, viewer_id) do
    comments = case inc.comments do
      %Ecto.Association.NotLoaded{} -> []
      comments -> Enum.map(comments, &comment_json/1)
    end

    # Pour `:council_only`, on ne renvoie JAMAIS l'identité du signaleur,
    # même au syndic / conseil — ni au signaleur lui-même via cet objet
    # `reporter`. La règle métier est : "ton nom n'apparaît nulle part".
    # Le frontend reçoit `viewer_is_reporter` plus bas pour savoir s'il
    # doit afficher "ton signalement", sans avoir à exposer l'UUID.
    reporter =
      cond do
        inc.visibility == :council_only -> nil
        true -> maybe_user(inc.reporter)
      end

    # Lot/locale qui pourraient permettre d'identifier indirectement le
    # signaleur sont masqués aussi sur `:council_only`.
    location = if inc.visibility == :council_only, do: nil, else: inc.location
    lot_number = if inc.visibility == :council_only, do: nil, else: inc.lot_number

    # Flag dérivé : le viewer EST-il l'auteur ? Calculé côté serveur pour
    # ne jamais exposer `reporter_id` côté client. Le frontend l'utilise
    # pour différencier le badge ("Visible par toi et le conseil" vs
    # "Signalement confidentiel — auteur masqué").
    viewer_is_reporter = not is_nil(viewer_id) and inc.reporter_id == viewer_id

    %{
      id: inc.id,
      title: inc.title,
      description: inc.description,
      category: inc.category,
      severity: inc.severity,
      status: inc.status,
      photo_urls: inc.photo_urls,
      location: location,
      lot_number: lot_number,
      resolution_note: inc.resolution_note,
      resolved_at: inc.resolved_at,
      building_id: inc.building_id,
      visibility: inc.visibility,
      reporter: reporter,
      assignee: maybe_user(inc.assignee),
      ai_answer: inc.ai_answer,
      ai_answered_at: inc.ai_answered_at,
      ai_model: inc.ai_model,
      ai_answer_confirmed_at: inc.ai_answer_confirmed_at,
      ai_answer_confirmed_by_id: inc.ai_answer_confirmed_by_id,
      comments: comments,
      inserted_at: inc.inserted_at,
      updated_at: inc.updated_at,
      # `viewer_privileged` indique au front si l'utilisateur peut voir
      # les incidents `:council_only` (utile pour afficher l'onglet ou le
      # filtre adapté). Ne révèle pas qui a signalé pour autant.
      viewer_privileged: privileged?,
      viewer_is_reporter: viewer_is_reporter
    }
  end

  defp comment_json(c), do: %{
    id: c.id,
    body: c.body,
    is_internal: c.is_internal,
    incident_id: c.incident_id,
    author_id: c.author_id,
    author_name: if(c.author, do: author_name(c.author), else: nil),
    author_avatar_url: if(c.author, do: c.author.avatar_url, else: nil),
    inserted_at: c.inserted_at
  }

  defp author_name(u) do
    if u.first_name && u.last_name, do: "#{u.first_name} #{u.last_name}", else: u.email
  end

  defp maybe_user(nil), do: nil
  defp maybe_user(u), do: %{id: u.id, email: u.email, first_name: u.first_name, last_name: u.last_name, avatar_url: u.avatar_url}

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
