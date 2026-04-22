defmodule KomunBackendWeb.DevisController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Projects}
  alias KomunBackend.AI.DevisAnalyzer
  alias KomunBackend.Auth.Guardian
  alias KomunBackendWeb.ProjectController

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  # POST /api/v1/buildings/:building_id/projects/:project_id/devis
  #
  # Accepts either multipart/form-data (with `file`) or JSON. Any building
  # member can upload a devis.
  def create(conn, %{"building_id" => building_id, "project_id" => project_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         project when not is_nil(project) <- Projects.get_project(building_id, project_id) do
      attrs = build_devis_attrs(params)

      case Projects.create_devis(project.id, user.id, attrs) do
        {:ok, devis} ->
          conn |> put_status(:created) |> json(%{data: ProjectController.devis_json(devis)})

        {:error, cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
      end
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Projet introuvable"})
    end
  end

  # DELETE /api/v1/buildings/:building_id/projects/:project_id/devis/:id
  def delete(conn, %{"building_id" => building_id, "project_id" => project_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         devis when not is_nil(devis) <- Projects.get_devis(project_id, id),
         :ok <- authorize_delete(user, building_id, devis),
         {:ok, _} <- Projects.delete_devis(devis) do
      send_resp(conn, :no_content, "")
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Devis introuvable"})
      {:error, :forbidden} -> conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
      {:error, _} -> conn |> put_status(:unprocessable_entity) |> json(%{error: "Suppression impossible"})
    end
  end

  # POST /api/v1/buildings/:building_id/projects/:project_id/devis/:id/analyze
  #
  # Runs the Groq analysis synchronously and returns the updated devis. Only
  # privileged roles can trigger it — the call costs Groq credits.
  def analyze(conn, %{"building_id" => building_id, "project_id" => project_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- require_privileged(conn, user, building_id),
         project when not is_nil(project) <- Projects.get_project(building_id, project_id),
         devis when not is_nil(devis) <- Projects.get_devis(project.id, id) do
      run_analysis(conn, project, devis)
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "Ressource introuvable"})
      {:error, :forbidden} -> conn |> put_status(:forbidden) |> json(%{error: "Action réservée au syndic ou au conseil syndical."})
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp run_analysis(conn, project, devis) do
    case devis.content_text do
      text when is_binary(text) and text != "" ->
        case DevisAnalyzer.analyze(text, project_title: project.title) do
          {:ok, analysis, model} ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)

            case Projects.update_devis(devis, %{
                   analysis: analysis,
                   analyzed_at: now,
                   analysis_model: model
                 }) do
              {:ok, updated} ->
                updated = KomunBackend.Repo.preload(updated, :uploaded_by)
                json(conn, %{data: ProjectController.devis_json(updated)})

              {:error, cs} ->
                conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
            end

          {:error, :missing_api_key} ->
            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "L'analyse IA n'est pas configurée (clé GROQ manquante)."})

          {:error, :invalid_json} ->
            conn
            |> put_status(:bad_gateway)
            |> json(%{error: "L'IA a renvoyé une réponse non exploitable. Réessayez."})

          {:error, reason} ->
            conn
            |> put_status(:bad_gateway)
            |> json(%{error: "L'analyse IA a échoué : #{inspect(reason)}"})
        end

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Le devis n'a pas de texte extrait. Uploadez un PDF exploitable."})
    end
  end

  defp build_devis_attrs(%{"devis" => json_attrs} = params) when is_map(json_attrs) do
    file = Map.get(params, "file")
    base = normalize(json_attrs)

    case file do
      %Plug.Upload{} = upload -> Map.merge(base, save_upload(upload))
      _ -> base
    end
  end

  defp build_devis_attrs(params) do
    # Multipart without a `devis` envelope — read top-level form fields.
    file = Map.get(params, "file")

    base = %{
      "vendor_name" => params["vendor_name"] || params["vendor"] || "",
      "content_text" => params["content_text"]
    }

    case file do
      %Plug.Upload{} = upload -> Map.merge(base, save_upload(upload))
      _ -> base
    end
  end

  defp normalize(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp save_upload(%Plug.Upload{filename: filename, path: tmp_path, content_type: ctype}) do
    ext = Path.extname(filename)
    unique_name = "#{System.unique_integer([:positive, :monotonic])}#{ext}"
    dest_dir = Application.app_dir(:komun_backend, "priv/static/uploads/devis")
    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, unique_name)

    case File.cp(tmp_path, dest_path) do
      :ok ->
        %{
          "file_url" => "uploads/devis/#{unique_name}",
          "filename" => filename,
          "file_size_bytes" => file_size(tmp_path),
          "mime_type" => ctype
        }

      {:error, _} ->
        %{}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
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

  # An uploader can delete their own devis; privileged roles can delete any.
  defp authorize_delete(user, building_id, devis) do
    member_role = Buildings.get_member_role(building_id, user.id)

    cond do
      user.role in @privileged_roles or member_role in @privileged_roles -> :ok
      devis.uploaded_by_id == user.id -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
