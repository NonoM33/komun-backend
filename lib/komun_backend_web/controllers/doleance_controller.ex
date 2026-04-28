defmodule KomunBackendWeb.DoleanceController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Doleances, Projects}
  alias KomunBackend.Doleances.DoleanceFile
  alias KomunBackend.AI.DoleanceDossier
  alias KomunBackend.Auth.Guardian

  # Bornes alignées avec les diligences et les incidents (15 Mo, mêmes
  # mime-types) — même UX côté front (un seul composant FileQueue partagé).
  @max_upload_bytes 15 * 1024 * 1024
  @allowed_mime_types ~w(application/pdf image/jpeg image/png image/heic image/webp)
  @photo_mime_types ~w(image/jpeg image/png image/heic image/webp)

  # GET /api/v1/buildings/:building_id/doleances
  def index(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      doleances = Doleances.list_doleances(building_id, params, user)
      json(conn, %{data: Enum.map(doleances, &doleance_json/1)})
    end
  end

  # GET /api/v1/buildings/:building_id/doleances/:id
  def show(conn, %{"building_id" => building_id, "id" => id}) do
    with :ok <- authorize_building(conn, building_id) do
      doleance = Doleances.get_doleance!(id)
      linked_projects = Projects.list_projects_linked_to_doleance(doleance.id)

      payload =
        doleance
        |> doleance_json()
        |> Map.put(:linked_projects, Enum.map(linked_projects, &linked_project_brief/1))

      json(conn, %{data: payload})
    end
  end

  # POST /api/v1/buildings/:building_id/doleances
  def create(conn, %{"building_id" => building_id, "doleance" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         {:ok, doleance} <- Doleances.create_doleance(building_id, user.id, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: doleance_json(doleance)})
    else
      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  # PUT /api/v1/buildings/:building_id/doleances/:id
  #
  # Edit is limited to the author and privileged members. Résidents
  # lambda can't touch a doléance they didn't open — they should
  # co-sign and add their own testimony instead.
  def update(conn, %{"building_id" => building_id, "id" => id, "doleance" => attrs}) do
    user = Guardian.Plug.current_resource(conn)
    doleance = Doleances.get_doleance!(id)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_author_or_privileged(conn, building_id, user, doleance) do
      case Doleances.update_doleance(doleance, attrs, user.id) do
        {:ok, updated} -> json(conn, %{data: doleance_json(updated)})
        {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
      end
    end
  end

  # DELETE /api/v1/buildings/:building_id/doleances/:id
  def delete(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)
    doleance = Doleances.get_doleance!(id)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_author_or_privileged(conn, building_id, user, doleance) do
      {:ok, _} = Doleances.delete_doleance(doleance)
      send_resp(conn, :no_content, "")
    end
  end

  # POST /api/v1/buildings/:building_id/doleances/:id/support
  #
  # Upsert the current user's co-signature (comment + optional photos).
  def add_support(conn, params) do
    %{"building_id" => building_id, "doleance_id" => doleance_id} = params
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "support", %{})

    with :ok <- authorize_building(conn, building_id),
         {:ok, _support} <- Doleances.upsert_support(doleance_id, user.id, attrs) do
      doleance = Doleances.get_doleance!(doleance_id)
      json(conn, %{data: doleance_json(doleance)})
    else
      {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
    end
  end

  # DELETE /api/v1/buildings/:building_id/doleances/:id/support
  def remove_support(conn, %{"building_id" => building_id, "doleance_id" => doleance_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      :ok = Doleances.remove_support(doleance_id, user.id)
      doleance = Doleances.get_doleance!(doleance_id)
      json(conn, %{data: doleance_json(doleance)})
    end
  end

  # POST /api/v1/buildings/:building_id/doleances/:id/generate-letter
  def generate_letter(conn, %{"building_id" => building_id, "doleance_id" => doleance_id}) do
    user = Guardian.Plug.current_resource(conn)
    doleance = Doleances.get_doleance!(doleance_id)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_author_or_privileged(conn, building_id, user, doleance) do
      case DoleanceDossier.generate_letter(doleance, user.id) do
        {:ok, updated} -> json(conn, %{data: doleance_json(updated)})
        {:error, :no_ai_key} -> conn |> put_status(:service_unavailable) |> json(%{error: "L'assistant IA est désactivé sur cet environnement."})
        {:error, reason} -> conn |> put_status(:bad_gateway) |> json(%{error: "Génération IA échouée : #{inspect(reason)}"})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/doleances/:id/suggest-experts
  def suggest_experts(conn, %{"building_id" => building_id, "doleance_id" => doleance_id}) do
    user = Guardian.Plug.current_resource(conn)
    doleance = Doleances.get_doleance!(doleance_id)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_author_or_privileged(conn, building_id, user, doleance) do
      case DoleanceDossier.suggest_experts(doleance, user.id) do
        {:ok, updated} -> json(conn, %{data: doleance_json(updated)})
        {:error, :no_ai_key} -> conn |> put_status(:service_unavailable) |> json(%{error: "L'assistant IA est désactivé sur cet environnement."})
        {:error, reason} -> conn |> put_status(:bad_gateway) |> json(%{error: "Suggestions IA échouées : #{inspect(reason)}"})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/doleances/:id/escalate
  def escalate(conn, %{"building_id" => building_id, "doleance_id" => doleance_id}) do
    user = Guardian.Plug.current_resource(conn)
    doleance = Doleances.get_doleance!(doleance_id)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_author_or_privileged(conn, building_id, user, doleance),
         {:ok, updated} <- Doleances.escalate(doleance, user.id) do
      updated = KomunBackend.Repo.preload(updated, [:author, :files, supports: :user])
      json(conn, %{data: doleance_json(updated)})
    else
      {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
    end
  end

  # GET /api/v1/buildings/:building_id/doleances/:doleance_id/events
  #
  # Timeline visible aux copropriétaires uniquement (pas aux locataires).
  # Les locataires n'ont pas de parts dans la copropriété et ne sont pas
  # concernés par les démarches collectives du conseil.
  def events(conn, %{"building_id" => building_id, "doleance_id" => doleance_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_coproprietaire(conn, building_id, user) do
      event_list = Doleances.list_events(doleance_id)
      json(conn, %{data: Enum.map(event_list, &event_json/1)})
    end
  end

  # POST /api/v1/buildings/:building_id/doleances/:doleance_id/files (multipart)
  #
  # Tout membre actif du bâtiment peut joindre une pièce à une doléance
  # (les preuves font la force d'une plainte collective). La suppression
  # est en revanche réservée à l'auteur ou aux rôles privilégiés.
  def upload_file(conn, %{"building_id" => building_id, "doleance_id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      doleance = Doleances.get_doleance!(id)

      cond do
        doleance.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          do_upload(conn, doleance, user, params)
      end
    end
  end

  defp do_upload(conn, doleance, user, params) do
    upload = Map.get(params, "file")

    cond do
      not match?(%Plug.Upload{}, upload) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Fichier requis (multipart \"file\")"})
        |> halt()

      upload.content_type not in @allowed_mime_types ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "Type de fichier refusé (autorisés : PDF, JPEG, PNG, HEIC, WebP)"
        })
        |> halt()

      file_size(upload.path) > @max_upload_bytes ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Fichier trop volumineux (max #{@max_upload_bytes} octets)"})
        |> halt()

      true ->
        case save_upload(upload, doleance.id) do
          {:ok, relative_path} ->
            attrs = %{
              "kind" => infer_kind(params["kind"], upload.content_type),
              "filename" => upload.filename,
              "file_url" => "/" <> relative_path,
              "file_size_bytes" => file_size(upload.path),
              "mime_type" => upload.content_type
            }

            case Doleances.attach_file(doleance.id, user, attrs) do
              {:ok, _file} ->
                fresh = Doleances.get_doleance!(doleance.id)

                conn
                |> put_status(:created)
                |> json(%{data: doleance_json(fresh)})

              {:error, cs} ->
                conn
                |> put_status(:unprocessable_entity)
                |> json(%{errors: format_errors(cs)})
            end

          {:error, reason} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Échec de l'enregistrement : #{inspect(reason)}"})
        end
    end
  end

  # DELETE /api/v1/buildings/:building_id/doleances/:doleance_id/files/:file_id
  def delete_file(conn, %{
        "building_id" => building_id,
        "doleance_id" => id,
        "file_id" => file_id
      }) do
    user = Guardian.Plug.current_resource(conn)
    doleance = Doleances.get_doleance!(id)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_author_or_privileged(conn, building_id, user, doleance) do
      file = Doleances.get_file!(file_id)

      cond do
        doleance.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        file.doleance_id != doleance.id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          {:ok, _} = Doleances.delete_file(file)
          maybe_remove_file(file.file_url)
          send_resp(conn, :no_content, "")
      end
    end
  end

  # ── Authorization helpers ────────────────────────────────────────────────

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  # Locataires are explicitly excluded from the timeline — they can see the
  # doléance itself (as members of the building) but not the action history
  # which may reveal privileged council deliberations.
  @tenant_roles [:locataire]

  defp authorize_building(conn, building_id) do
    user = Guardian.Plug.current_resource(conn)

    if user.role == :super_admin or Buildings.member?(building_id, user.id) do
      :ok
    else
      conn |> put_status(403) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp authorize_coproprietaire(conn, building_id, user) do
    member_role = Buildings.get_member_role(building_id, user.id)

    cond do
      user.role == :super_admin -> :ok
      user.role in @privileged_roles -> :ok
      member_role in @privileged_roles -> :ok
      user.role in @tenant_roles ->
        conn |> put_status(403) |> json(%{error: "Réservé aux copropriétaires."}) |> halt()
      member_role in @tenant_roles ->
        conn |> put_status(403) |> json(%{error: "Réservé aux copropriétaires."}) |> halt()
      true -> :ok
    end
  end

  defp authorize_author_or_privileged(conn, building_id, user, doleance) do
    member_role = Buildings.get_member_role(building_id, user.id)

    cond do
      to_string(doleance.author_id) == to_string(user.id) -> :ok
      user.role == :super_admin -> :ok
      user.role in @privileged_roles -> :ok
      member_role in @privileged_roles -> :ok
      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Seul l'auteur ou le conseil / syndic peut modifier cette doléance."})
        |> halt()
    end
  end

  # ── Serialization ────────────────────────────────────────────────────────

  defp doleance_json(d) do
    %{
      id: d.id,
      title: d.title,
      description: d.description,
      category: d.category,
      severity: d.severity,
      status: d.status,
      photo_urls: d.photo_urls,
      document_urls: d.document_urls,
      files: files_json(d.files),
      target_kind: d.target_kind,
      target_name: d.target_name,
      target_email: d.target_email,
      ai_letter: d.ai_letter,
      ai_letter_generated_at: d.ai_letter_generated_at,
      ai_expert_suggestions: d.ai_expert_suggestions,
      ai_suggestions_generated_at: d.ai_suggestions_generated_at,
      ai_model: d.ai_model,
      escalated_at: d.escalated_at,
      resolved_at: d.resolved_at,
      resolution_note: d.resolution_note,
      building_id: d.building_id,
      author: maybe_user(d.author),
      supports: supports_json(d.supports),
      support_count: length(supports_list(d.supports)),
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  defp event_json(e) do
    %{
      id: e.id,
      event_type: e.event_type,
      payload: e.payload,
      actor: maybe_user(e.actor),
      inserted_at: e.inserted_at
    }
  end

  defp supports_json(%Ecto.Association.NotLoaded{}), do: []
  defp supports_json(nil), do: []

  defp supports_json(list) when is_list(list) do
    Enum.map(list, fn s ->
      %{
        id: s.id,
        comment: s.comment,
        photo_urls: s.photo_urls,
        user: maybe_user(s.user),
        inserted_at: s.inserted_at,
        updated_at: s.updated_at
      }
    end)
  end

  defp supports_list(%Ecto.Association.NotLoaded{}), do: []
  defp supports_list(nil), do: []
  defp supports_list(l) when is_list(l), do: l

  defp maybe_user(%Ecto.Association.NotLoaded{}), do: nil
  defp maybe_user(nil), do: nil

  defp maybe_user(u) do
    %{
      id: u.id,
      email: u.email,
      first_name: u.first_name,
      last_name: u.last_name,
      avatar_url: u.avatar_url
    }
  end

  # Brief utilisé pour la section « Devis demandés » de la fiche doléance.
  defp linked_project_brief(p) do
    devis_count =
      case p.devis do
        %Ecto.Association.NotLoaded{} -> 0
        list when is_list(list) -> length(list)
      end

    %{
      id: p.id,
      title: p.title,
      status: p.status,
      devis_count: devis_count
    }
  end

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp files_json(%Ecto.Association.NotLoaded{}), do: []
  defp files_json(nil), do: []

  defp files_json(list) when is_list(list) do
    Enum.map(list, fn %DoleanceFile{} = f ->
      %{
        id: f.id,
        kind: f.kind,
        filename: f.filename,
        file_url: f.file_url,
        file_size_bytes: f.file_size_bytes,
        mime_type: f.mime_type,
        uploaded_by_id: f.uploaded_by_id,
        inserted_at: f.inserted_at
      }
    end)
  end

  # ── Upload helpers ────────────────────────────────────────────────────────

  defp save_upload(%Plug.Upload{filename: filename, path: tmp_path}, doleance_id) do
    ext = Path.extname(filename)
    unique_name = "#{System.unique_integer([:positive, :monotonic])}#{ext}"

    dest_dir =
      Application.app_dir(
        :komun_backend,
        "priv/static/uploads/doleances/#{doleance_id}"
      )

    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, unique_name)

    case File.cp(tmp_path, dest_path) do
      :ok -> {:ok, "uploads/doleances/#{doleance_id}/#{unique_name}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp infer_kind(kind, _mime) when kind in ["photo", "document"], do: kind

  defp infer_kind(_, mime) when is_binary(mime) do
    if mime in @photo_mime_types, do: "photo", else: "document"
  end

  defp infer_kind(_, _), do: "document"

  defp maybe_remove_file("/" <> rel) do
    abs = Application.app_dir(:komun_backend, Path.join("priv/static", rel))

    case File.rm(abs) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("[doleances] could not remove #{abs}: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_remove_file(_), do: :ok
end
