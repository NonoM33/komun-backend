defmodule KomunBackendWeb.DocumentController do
  use KomunBackendWeb, :controller

  alias KomunBackend.Documents
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
      inserted_at: d.inserted_at,
      uploaded_by: if(d.uploaded_by, do: %{
        id: d.uploaded_by.id,
        first_name: d.uploaded_by.first_name,
        last_name: d.uploaded_by.last_name,
        email: d.uploaded_by.email
      }, else: nil)
    }
  end

  def index(conn, %{"building_id" => building_id}) do
    docs = Documents.list_documents(building_id)
    json(conn, %{data: Enum.map(docs, &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    doc = Documents.get_document!(id)
    json(conn, %{data: serialize(doc)})
  end

  def create(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with %Plug.Upload{} = upload <- Map.get(params, "file"),
         {:ok, relative_path} <- save_upload(upload) do
      attrs = %{
        title: Map.get(params, "title", upload.filename),
        filename: upload.filename,
        file_url: "/" <> relative_path,
        category: Map.get(params, "category", "autre"),
        file_size_bytes: file_size(upload.path),
        mime_type: upload.content_type
      }

      case Documents.create_document(building_id, user.id, attrs) do
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
    else
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Fichier manquant"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Échec de l'enregistrement du fichier : #{reason}"})
    end
  end

  def update(conn, _params), do: json(conn, %{data: %{}})
  def delete(conn, _params), do: send_resp(conn, :no_content, "")

  # ── Private helpers ─────────────────────────────────────────────────────────

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
