defmodule KomunBackend.Documents do
  @moduledoc "Documents context."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Documents.Document

  def list_documents(building_id) do
    from(d in Document,
      where: d.building_id == ^building_id and d.is_public == true,
      order_by: [desc: d.inserted_at],
      preload: [:uploaded_by]
    )
    |> Repo.all()
  end

  def get_document!(id), do: Repo.get!(Document, id) |> Repo.preload(:uploaded_by)

  def create_document(building_id, uploader_id, attrs) do
    %Document{}
    |> Document.changeset(Map.merge(attrs, %{building_id: building_id, uploaded_by_id: uploader_id}))
    |> Repo.insert()
  end
end
