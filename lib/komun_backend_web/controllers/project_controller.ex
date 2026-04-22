defmodule KomunBackendWeb.ProjectController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Projects}
  alias KomunBackend.Auth.Guardian

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  # GET /api/v1/buildings/:building_id/projects
  def index(conn, %{"building_id" => building_id}) do
    with :ok <- authorize_building(conn, building_id) do
      projects = Projects.list_projects(building_id)
      json(conn, %{data: Enum.map(projects, &project_json/1)})
    end
  end

  # GET /api/v1/buildings/:building_id/projects/:id
  def show(conn, %{"building_id" => building_id, "id" => id}) do
    with :ok <- authorize_building(conn, building_id) do
      case Projects.get_project(building_id, id) do
        nil ->
          conn |> put_status(:not_found) |> json(%{error: "Projet introuvable"})

        project ->
          json(conn, %{data: project_json(project)})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/projects
  def create(conn, %{"building_id" => building_id, "project" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- require_privileged(conn, user, building_id),
         {:ok, project} <- Projects.create_project(building_id, user.id, attrs) do
      conn |> put_status(:created) |> json(%{data: project_json(project)})
    else
      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "Seul le conseil syndical ou le syndic peut créer un projet."})

      {:error, %Ecto.Changeset{} = cs} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
    end
  end

  # PATCH /api/v1/buildings/:building_id/projects/:id
  def update(conn, %{"building_id" => building_id, "id" => id, "project" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- require_privileged(conn, user, building_id),
         project when not is_nil(project) <- Projects.get_project(building_id, id),
         {:ok, updated} <- Projects.update_project(project, attrs) do
      json(conn, %{data: project_json(updated)})
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Projet introuvable"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "Action réservée au syndic ou au conseil syndical."})

      {:error, %Ecto.Changeset{} = cs} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
    end
  end

  # DELETE /api/v1/buildings/:building_id/projects/:id
  def delete(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- require_privileged(conn, user, building_id),
         project when not is_nil(project) <- Projects.get_project(building_id, id),
         {:ok, _} <- Projects.delete_project(project) do
      send_resp(conn, :no_content, "")
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Projet introuvable"})
      {:error, :forbidden} -> conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
      {:error, _} -> conn |> put_status(:unprocessable_entity) |> json(%{error: "Suppression impossible"})
    end
  end

  # POST /api/v1/buildings/:building_id/projects/:id/start-vote
  # Body: { "devis_id": uuid, "ends_at": iso8601 | null, "description": string | null }
  def start_vote(conn, %{"building_id" => building_id, "id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    devis_id = params["devis_id"]
    ends_at = params["ends_at"]
    description = params["description"]

    if not is_binary(devis_id) or devis_id == "" do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "devis_id est requis pour lancer le vote."})
    else
      with :ok <- authorize_building(conn, building_id),
           :ok <- require_privileged(conn, user, building_id),
           project when not is_nil(project) <- Projects.get_project(building_id, id),
           {:ok, updated} <-
             Projects.start_vote(project, user.id, devis_id,
               ends_at: parse_ends_at(ends_at),
               description: description
             ) do
        json(conn, %{data: project_json(updated)})
      else
        nil ->
          conn |> put_status(:not_found) |> json(%{error: "Projet introuvable"})

        {:error, :forbidden} ->
          conn |> put_status(:forbidden) |> json(%{error: "Action réservée au syndic ou au conseil syndical."})

        {:error, :devis_not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Devis introuvable dans ce projet."})

        {:error, :already_voting} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "Un vote est déjà en cours pour ce projet."})

        {:error, %Ecto.Changeset{} = cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
      end
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp parse_ends_at(nil), do: nil
  defp parse_ends_at(""), do: nil
  defp parse_ends_at(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp authorize_building(conn, building_id) do
    user = Guardian.Plug.current_resource(conn)

    if user.role == :super_admin or Buildings.member?(building_id, user.id) do
      :ok
    else
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp require_privileged(_conn, user, building_id) do
    member_role = Buildings.get_member_role(building_id, user.id)

    if user.role in @privileged_roles or member_role in @privileged_roles do
      :ok
    else
      {:error, :forbidden}
    end
  end

  @doc false
  def project_json(project) do
    %{
      id: project.id,
      title: project.title,
      description: project.description,
      status: project.status,
      building_id: project.building_id,
      chosen_devis_id: project.chosen_devis_id,
      vote_id: project.vote_id,
      vote: vote_brief(project.vote),
      created_by: maybe_user(project.created_by),
      devis: devis_list(project.devis),
      inserted_at: project.inserted_at,
      updated_at: project.updated_at
    }
  end

  defp devis_list(%Ecto.Association.NotLoaded{}), do: []
  defp devis_list(list) when is_list(list), do: Enum.map(list, &devis_json/1)

  @doc false
  def devis_json(devis) do
    %{
      id: devis.id,
      project_id: devis.project_id,
      vendor_name: devis.vendor_name,
      file_url: devis.file_url,
      filename: devis.filename,
      file_size_bytes: devis.file_size_bytes,
      mime_type: devis.mime_type,
      has_content_text: is_binary(devis.content_text) and devis.content_text != "",
      analysis: devis.analysis,
      analyzed_at: devis.analyzed_at,
      analysis_model: devis.analysis_model,
      uploaded_by: maybe_user(devis.uploaded_by),
      inserted_at: devis.inserted_at
    }
  end

  defp vote_brief(%Ecto.Association.NotLoaded{}), do: nil
  defp vote_brief(nil), do: nil
  defp vote_brief(vote),
    do: %{id: vote.id, status: vote.status, ends_at: vote.ends_at, title: vote.title}

  defp maybe_user(%Ecto.Association.NotLoaded{}), do: nil
  defp maybe_user(nil), do: nil
  defp maybe_user(u) do
    name = if u.first_name && u.last_name, do: "#{u.first_name} #{u.last_name}", else: u.email
    %{id: u.id, name: name, email: u.email}
  end

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
