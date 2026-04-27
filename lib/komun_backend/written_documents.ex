defmodule KomunBackend.WrittenDocuments do
  @moduledoc """
  Documents rédigés en ligne (PV de conseil, comptes-rendus, …) via
  l'éditeur Notion-like. Schéma jumeau de `Articles.Article` mais
  rangé sous une catégorie `KomunBackend.Documents.Document` pour que
  la UI fusionne les deux types dans la même page Documents.

  Workflow éditorial : draft → review → published → archived.
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.WrittenDocuments.WrittenDocument

  # Aligné sur Documents.uploader_roles/0 pour rester cohérent.
  @editor_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  def editor_roles, do: @editor_roles

  @doc """
  Liste les documents rédigés d'un bâtiment. Par défaut affiche
  uniquement les `published` non-archivés (vue voisin). Les éditeurs
  passent `status: :all` pour voir aussi les brouillons.
  """
  def list_written_documents(building_id, opts \\ []) do
    status = Keyword.get(opts, :status, :published)
    archived = Keyword.get(opts, :archived, false)

    base =
      from(d in WrittenDocument,
        where: d.building_id == ^building_id,
        order_by: [
          desc: d.is_pinned,
          desc: coalesce(d.published_at, d.inserted_at)
        ],
        preload: [:author]
      )

    base =
      if archived do
        where(base, [d], d.is_archived == true)
      else
        where(base, [d], d.is_archived == false)
      end

    query =
      case status do
        :all -> base
        s when s in [:draft, :review, :published, :archived] -> where(base, [d], d.status == ^s)
        _ -> where(base, [d], d.status == :published)
      end

    Repo.all(query)
  end

  def get_written_document!(id),
    do: Repo.get!(WrittenDocument, id) |> Repo.preload(:author)

  def create_written_document(building_id, author_id, attrs) do
    %WrittenDocument{}
    |> WrittenDocument.changeset(
      Map.merge(attrs, %{building_id: building_id, author_id: author_id})
    )
    |> Repo.insert()
  end

  def update_written_document(%WrittenDocument{} = doc, attrs) do
    doc
    |> WrittenDocument.changeset(attrs)
    |> Repo.update()
  end

  def transition(%WrittenDocument{} = doc, status, reviewer_note \\ nil) do
    doc
    |> WrittenDocument.transition_changeset(%{status: status, reviewer_note: reviewer_note})
    |> Repo.update()
  end

  def archive(%WrittenDocument{} = doc) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    doc
    |> WrittenDocument.changeset(%{is_archived: true, archived_at: now, is_pinned: false})
    |> Repo.update()
  end

  def unarchive(%WrittenDocument{} = doc) do
    doc
    |> WrittenDocument.changeset(%{is_archived: false, archived_at: nil})
    |> Repo.update()
  end

  def delete_written_document(%WrittenDocument{} = doc), do: Repo.delete(doc)
end
