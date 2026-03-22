defmodule KomunBackendWeb.DocumentController do
  use KomunBackendWeb, :controller

  alias KomunBackend.Documents

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

  def create(conn, _params), do: conn |> put_status(:created) |> json(%{data: %{}})
  def update(conn, _params), do: json(conn, %{data: %{}})
  def delete(conn, _params), do: send_resp(conn, :no_content, "")
end
