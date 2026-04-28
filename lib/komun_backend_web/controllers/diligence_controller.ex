defmodule KomunBackendWeb.DiligenceController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Diligences, Projects}
  alias KomunBackend.Diligences.{Diligence, DiligenceFile, Steps}
  alias KomunBackend.Auth.Guardian

  # Borne d'upload : on autorise large pour pouvoir attacher un journal
  # détaillé sur plusieurs mois ou un constat d'huissier scanné en HD,
  # mais pas le scan d'un livre entier. Ajustable plus tard si besoin.
  @max_upload_bytes 15 * 1024 * 1024
  @allowed_mime_types ~w(application/pdf image/jpeg image/png image/heic image/webp)

  # GET /api/v1/buildings/:building_id/diligences
  def index(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      diligences = Diligences.list_diligences(building_id, params)
      json(conn, %{data: Enum.map(diligences, &diligence_json/1)})
    end
  end

  # GET /api/v1/buildings/:building_id/diligences/:id
  def show(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      diligence = Diligences.get_diligence!(id)

      if diligence.building_id == building_id do
        linked_projects = Projects.list_projects_linked_to_diligence(diligence.id)

        payload =
          diligence
          |> diligence_json()
          |> Map.put(:linked_projects, Enum.map(linked_projects, &linked_project_brief/1))

        json(conn, %{data: payload})
      else
        # Garde-fou : un membre du bâtiment A ne doit pas pouvoir
        # piocher dans les diligences du bâtiment B en passant le
        # bon `building_id` dans l'URL et un `id` qui ne lui appartient pas.
        conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()
      end
    end
  end

  # POST /api/v1/buildings/:building_id/diligences
  def create(conn, %{"building_id" => building_id, "diligence" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user),
         {:ok, diligence} <- Diligences.create_diligence(building_id, user, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: diligence_json(diligence)})
    else
      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})
        |> halt()

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
        |> halt()

      # `authorize_privileged/3` renvoie déjà le conn halted en cas
      # d'échec d'autorisation (403 / 401). On le propage tel quel.
      %Plug.Conn{} = halted ->
        halted
    end
  end

  # PATCH /api/v1/buildings/:building_id/diligences/:id
  def update(conn, %{"building_id" => building_id, "id" => id, "diligence" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      diligence = Diligences.get_diligence!(id)

      cond do
        diligence.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          case Diligences.update_diligence(diligence, attrs) do
            {:ok, updated} ->
              json(conn, %{data: diligence_json(updated)})

            {:error, cs} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(cs)})
          end
      end
    end
  end

  # PATCH /api/v1/buildings/:building_id/diligences/:id/steps/:step_number
  def update_step(conn, %{
        "building_id" => building_id,
        "id" => id,
        "step_number" => step_str,
        "step" => attrs
      }) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user),
         {step_number, ""} <- Integer.parse(step_str),
         true <- Steps.valid_number?(step_number) do
      diligence = Diligences.get_diligence!(id)

      cond do
        diligence.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          case Diligences.update_step(diligence.id, step_number, attrs) do
            {:ok, _step} ->
              fresh = Diligences.get_diligence!(diligence.id)
              json(conn, %{data: diligence_json(fresh)})

            {:error, :not_found} ->
              conn |> put_status(:not_found) |> json(%{error: "Step not found"}) |> halt()

            {:error, cs} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(cs)})
          end
      end
    else
      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid step_number (must be 1..#{Steps.count()})"})
        |> halt()
    end
  end

  # POST /api/v1/buildings/:building_id/diligences/:id/files (multipart)
  def upload_file(conn, %{"building_id" => building_id, "id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      diligence = Diligences.get_diligence!(id)

      cond do
        diligence.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          do_upload(conn, diligence, user, params)
      end
    end
  end

  defp do_upload(conn, diligence, user, params) do
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
          error:
            "Type de fichier refusé (autorisés : PDF, JPEG, PNG, HEIC, WebP)"
        })
        |> halt()

      file_size(upload.path) > @max_upload_bytes ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Fichier trop volumineux (max #{@max_upload_bytes} octets)"})
        |> halt()

      true ->
        case save_upload(upload, diligence.id) do
          {:ok, relative_path} ->
            attrs = %{
              "kind" => Map.get(params, "kind", "autre"),
              "step_number" => parse_step(params["step_number"]),
              "filename" => upload.filename,
              "file_url" => "/" <> relative_path,
              "file_size_bytes" => file_size(upload.path),
              "mime_type" => upload.content_type
            }

            case Diligences.attach_file(diligence.id, user, attrs) do
              {:ok, _file} ->
                fresh = Diligences.get_diligence!(diligence.id)
                conn |> put_status(:created) |> json(%{data: diligence_json(fresh)})

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

  # POST /api/v1/buildings/:building_id/diligences/:id/generate-letter
  # Body : { "kind": "saisine" | "mise_en_demeure" }
  def generate_letter(conn, %{"building_id" => building_id, "id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    raw_kind = Map.get(params, "kind")

    with :ok <- authorize_privileged(conn, building_id, user),
         {:ok, kind} <- parse_kind(raw_kind) do
      diligence = Diligences.get_diligence!(id)

      cond do
        diligence.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          case KomunBackend.AI.DiligenceLetter.generate_letter(diligence, kind) do
            {:ok, updated} ->
              json(conn, %{data: diligence_json(updated)})

            {:error, cs} when is_struct(cs, Ecto.Changeset) ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(cs)})

            {:error, reason} ->
              conn
              |> put_status(:bad_gateway)
              |> json(%{error: "Échec de la génération : #{inspect(reason)}"})
          end
      end
    else
      {:error, :invalid_kind} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "kind doit être \"saisine\" ou \"mise_en_demeure\""})
        |> halt()

      %Plug.Conn{} = halted ->
        halted
    end
  end

  defp parse_kind("saisine"), do: {:ok, :saisine}
  defp parse_kind("mise_en_demeure"), do: {:ok, :mise_en_demeure}
  defp parse_kind(_), do: {:error, :invalid_kind}

  # DELETE /api/v1/buildings/:building_id/diligences/:id/files/:file_id
  def delete_file(conn, %{
        "building_id" => building_id,
        "id" => id,
        "file_id" => file_id
      }) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      diligence = Diligences.get_diligence!(id)
      file = Diligences.get_file!(file_id)

      cond do
        diligence.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        file.diligence_id != diligence.id ->
          # Le file_id appartient à une autre diligence — on ne laisse
          # pas un appelant deviner l'existence d'une pièce qui n'est
          # pas la sienne.
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          {:ok, _} = Diligences.delete_file(file)
          maybe_remove_file(file.file_url)
          send_resp(conn, :no_content, "")
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  defp authorize_privileged(conn, building_id, user) do
    cond do
      is_nil(user) ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"}) |> halt()

      user.role == :super_admin ->
        :ok

      user.role in @privileged_roles ->
        :ok

      Buildings.get_member_role(building_id, user.id) in @privileged_roles ->
        :ok

      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "Seuls le syndic et le conseil syndical peuvent accéder aux diligences."
        })
        |> halt()
    end
  end

  defp diligence_json(%Diligence{} = d) do
    steps =
      case d.steps do
        %Ecto.Association.NotLoaded{} -> []
        steps -> Enum.map(steps, &step_json/1)
      end

    files =
      case d.files do
        %Ecto.Association.NotLoaded{} -> []
        files -> Enum.map(files, &file_json/1)
      end

    %{
      id: d.id,
      title: d.title,
      description: d.description,
      status: d.status,
      source_type: d.source_type,
      source_label: d.source_label,
      saisine_syndic_letter: d.saisine_syndic_letter,
      mise_en_demeure_letter: d.mise_en_demeure_letter,
      building_id: d.building_id,
      linked_incident_id: d.linked_incident_id,
      created_by: maybe_user(d.created_by),
      steps: steps,
      files: files,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  defp step_json(s) do
    %{
      id: s.id,
      step_number: s.step_number,
      status: s.status,
      notes: s.notes,
      completed_at: s.completed_at,
      title: Steps.title(s.step_number),
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end

  defp file_json(f) do
    %{
      id: f.id,
      step_number: f.step_number,
      kind: f.kind,
      filename: f.filename,
      file_url: f.file_url,
      file_size_bytes: f.file_size_bytes,
      mime_type: f.mime_type,
      uploaded_by_id: f.uploaded_by_id,
      inserted_at: f.inserted_at
    }
  end

  defp maybe_user(%Ecto.Association.NotLoaded{}), do: nil
  defp maybe_user(nil), do: nil

  defp maybe_user(u),
    do: %{
      id: u.id,
      email: u.email,
      first_name: u.first_name,
      last_name: u.last_name,
      avatar_url: u.avatar_url
    }

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Brief utilisé pour la section « Devis demandés » de la fiche diligence.
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

  defp save_upload(%Plug.Upload{filename: filename, path: tmp_path}, diligence_id) do
    ext = Path.extname(filename)
    unique_name = "#{System.unique_integer([:positive, :monotonic])}#{ext}"

    # Stockage dans `priv/static/uploads/diligences/:diligence_id/` —
    # même base que les documents, mais isolé par diligence pour
    # qu'un `rm -rf` du dossier soit toujours sûr (purge complète d'un
    # dossier sans risque de zapper d'autres fichiers).
    dest_dir =
      Application.app_dir(
        :komun_backend,
        "priv/static/uploads/diligences/#{diligence_id}"
      )

    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, unique_name)

    case File.cp(tmp_path, dest_path) do
      :ok -> {:ok, "uploads/diligences/#{diligence_id}/#{unique_name}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp parse_step(nil), do: nil
  defp parse_step(""), do: nil

  defp parse_step(n) when is_integer(n) do
    if Steps.valid_number?(n), do: n, else: nil
  end

  defp parse_step(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> parse_step(n)
      _ -> nil
    end
  end

  defp parse_step(_), do: nil

  # Best-effort : si on n'arrive pas à supprimer le fichier (chemin
  # malformé, déjà parti…), la ligne en DB est déjà supprimée donc le
  # fichier orphelin est bénin. On loggue mais on ne casse pas le
  # contrat de l'endpoint.
  defp maybe_remove_file("/" <> rel) do
    abs = Application.app_dir(:komun_backend, Path.join("priv/static", rel))

    case File.rm(abs) do
      :ok -> :ok
      {:error, reason} -> require Logger; Logger.warning("[diligences] could not remove #{abs}: #{inspect(reason)}"); :ok
    end
  end

  defp maybe_remove_file(_), do: :ok
end
