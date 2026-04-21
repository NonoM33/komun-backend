defmodule KomunBackendWeb.DocumentController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Documents}
  alias KomunBackend.Auth.Guardian

  defp serialize(d) do
    %{
      id: d.id,
      title: d.title,
      filename: d.filename,
      file_url: d.file_url,
      category: d.category,
      file_size_bytes: d.file_size_bytes,
      mime_type: d.mime_type,
      is_pinned: d.is_pinned,
      has_content_text:
        is_binary(d.content_text) and String.length(String.trim(d.content_text)) > 0,
      inserted_at: d.inserted_at,
      uploaded_by:
        if(d.uploaded_by,
          do: %{
            id: d.uploaded_by.id,
            first_name: d.uploaded_by.first_name,
            last_name: d.uploaded_by.last_name,
            email: d.uploaded_by.email
          },
          else: nil
        )
    }
  end

  def index(conn, %{"building_id" => building_id}) do
    with :ok <- authorize_building(conn, building_id) do
      docs = Documents.list_documents(building_id)
      json(conn, %{data: Enum.map(docs, &serialize/1)})
    end
  end

  def show(conn, %{"id" => id}) do
    doc = Documents.get_document!(id)

    with :ok <- authorize_building(conn, doc.building_id) do
      json(conn, %{data: serialize(doc)})
    end
  end

  def create(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_upload(conn, building_id, user) do
      # Two payload shapes are accepted:
      #  - multipart with a :file (PDF, etc.) → we stage the upload
      #  - JSON body with :content_text only → no file, useful for pasting
      #    the règlement as plain text so the AI can use it immediately
      case Map.get(params, "file") do
        %Plug.Upload{} = upload ->
          case save_upload(upload) do
            {:ok, relative_path} ->
              attrs = %{
                title: Map.get(params, "title", upload.filename),
                filename: upload.filename,
                file_url: "/" <> relative_path,
                category: Map.get(params, "category", "autre"),
                file_size_bytes: file_size(upload.path),
                mime_type: upload.content_type,
                content_text: Map.get(params, "content_text"),
                is_pinned: truthy(Map.get(params, "is_pinned"))
              }

              persist(conn, building_id, user.id, attrs)

            {:error, reason} ->
              conn
              |> put_status(:internal_server_error)
              |> json(%{error: "Échec de l'enregistrement du fichier : #{reason}"})
          end

        nil ->
          content_text = Map.get(params, "content_text")

          if is_binary(content_text) and String.trim(content_text) != "" do
            attrs = %{
              title: Map.get(params, "title", "Document"),
              filename: nil,
              file_url: nil,
              category: Map.get(params, "category", "autre"),
              mime_type: "text/plain",
              content_text: content_text,
              is_pinned: truthy(Map.get(params, "is_pinned"))
            }

            persist(conn, building_id, user.id, attrs)
          else
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Fichier ou content_text requis"})
          end
      end
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    doc = Documents.get_document!(id)

    with :ok <- authorize_upload(conn, doc.building_id, user) do
      attrs =
        params
        |> Map.take(["title", "category", "content_text", "is_pinned", "is_public"])
        |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
        |> Enum.into(%{})

      case Documents.update_document(doc, attrs) do
        {:ok, updated} ->
          json(conn, %{data: serialize(KomunBackend.Repo.preload(updated, :uploaded_by))})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: format_errors(changeset)})
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)
    doc = Documents.get_document!(id)

    with :ok <- authorize_upload(conn, doc.building_id, user) do
      {:ok, _} = Documents.delete_document(doc)
      send_resp(conn, :no_content, "")
    end
  end

  # GET /api/v1/buildings/:building_id/documents/mandatory
  def mandatory(conn, %{"building_id" => building_id}) do
    with :ok <- authorize_building(conn, building_id) do
      json(conn, %{data: Documents.mandatory_status(building_id)})
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp persist(conn, building_id, user_id, attrs) do
    case Documents.create_document(building_id, user_id, attrs) do
      {:ok, doc} ->
        doc_with_uploader = KomunBackend.Repo.preload(doc, :uploaded_by)

        conn
        |> put_status(:created)
        |> json(%{data: serialize(doc_with_uploader)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_errors(changeset)})
    end
  end

  defp authorize_building(conn, building_id) do
    user = Guardian.Plug.current_resource(conn)

    cond do
      user.role == :super_admin ->
        :ok

      Buildings.member?(building_id, user.id) ->
        :ok

      true ->
        conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp authorize_upload(conn, building_id, user) do
    member_role = Buildings.get_member_role(building_id, user.id)

    cond do
      user.role == :super_admin -> :ok
      user.role in Documents.uploader_roles() -> :ok
      member_role in Documents.uploader_roles() -> :ok
      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Seuls le syndic et le conseil syndical peuvent modifier les documents."})
        |> halt()
    end
  end

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy("1"), do: true
  defp truthy(_), do: false

  defp save_upload(%Plug.Upload{filename: filename, path: tmp_path}) do
    ext = Path.extname(filename)
    unique_name = "#{System.unique_integer([:positive, :monotonic])}#{ext}"
    dest_dir = Application.app_dir(:komun_backend, "priv/static/uploads/documents")
    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, unique_name)

    case File.cp(tmp_path, dest_path) do
      :ok -> {:ok, "uploads/documents/#{unique_name}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
    |> Enum.join("; ")
  end
end
