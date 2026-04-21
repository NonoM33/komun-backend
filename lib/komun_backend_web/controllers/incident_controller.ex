defmodule KomunBackendWeb.IncidentController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Incidents}
  alias KomunBackend.Auth.Guardian

  # GET /api/v1/buildings/:building_id/incidents
  def index(conn, %{"building_id" => building_id} = params) do
    with :ok <- authorize_building(conn, building_id) do
      incidents = Incidents.list_incidents(building_id, params)
      json(conn, %{data: Enum.map(incidents, &incident_json/1)})
    end
  end

  # GET /api/v1/buildings/:building_id/incidents/:id
  def show(conn, %{"building_id" => building_id, "id" => id}) do
    with :ok <- authorize_building(conn, building_id) do
      incident = Incidents.get_incident!(id)
      json(conn, %{data: incident_json(incident)})
    end
  end

  # POST /api/v1/buildings/:building_id/incidents
  def create(conn, %{"building_id" => building_id, "incident" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         {:ok, incident} <- Incidents.create_incident(building_id, user.id, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: incident_json(incident)})
    else
      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  # PUT /api/v1/buildings/:building_id/incidents/:id
  def update(conn, %{"building_id" => building_id, "id" => id, "incident" => attrs}) do
    with :ok <- authorize_building(conn, building_id) do
      incident = Incidents.get_incident!(id)

      case Incidents.update_incident(incident, attrs) do
        {:ok, updated} -> json(conn, %{data: incident_json(updated)})
        {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
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

  # POST /api/v1/buildings/:building_id/incidents/:id/confirm-ai
  # Restricted to privileged members (syndic + conseil + super_admin).
  def confirm_ai_answer(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      incident = Incidents.get_incident!(id)

      case Incidents.confirm_ai_answer(incident, user.id) do
        {:ok, updated} ->
          updated = KomunBackend.Repo.preload(updated, [:reporter, :assignee, comments: :author])
          json(conn, %{data: incident_json(updated)})

        {:error, cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
      end
    end
  end

  # DELETE /api/v1/buildings/:building_id/incidents/:id/confirm-ai
  def unconfirm_ai_answer(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      incident = Incidents.get_incident!(id)

      case Incidents.unconfirm_ai_answer(incident) do
        {:ok, updated} ->
          updated = KomunBackend.Repo.preload(updated, [:reporter, :assignee, comments: :author])
          json(conn, %{data: incident_json(updated)})

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

  defp incident_json(inc) do
    comments = case inc.comments do
      %Ecto.Association.NotLoaded{} -> []
      comments -> Enum.map(comments, &comment_json/1)
    end

    %{
      id: inc.id,
      title: inc.title,
      description: inc.description,
      category: inc.category,
      severity: inc.severity,
      status: inc.status,
      photo_urls: inc.photo_urls,
      location: inc.location,
      lot_number: inc.lot_number,
      resolution_note: inc.resolution_note,
      resolved_at: inc.resolved_at,
      building_id: inc.building_id,
      reporter: maybe_user(inc.reporter),
      assignee: maybe_user(inc.assignee),
      ai_answer: inc.ai_answer,
      ai_answered_at: inc.ai_answered_at,
      ai_model: inc.ai_model,
      ai_answer_confirmed_at: inc.ai_answer_confirmed_at,
      ai_answer_confirmed_by_id: inc.ai_answer_confirmed_by_id,
      comments: comments,
      inserted_at: inc.inserted_at,
      updated_at: inc.updated_at
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
