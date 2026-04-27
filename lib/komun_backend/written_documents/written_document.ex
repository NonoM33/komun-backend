defmodule KomunBackend.WrittenDocuments.WrittenDocument do
  @moduledoc """
  Document rédigé directement dans l'app via l'éditeur Notion-like —
  typiquement un PV de conseil syndical ou un compte-rendu, par
  opposition à `KomunBackend.Documents.Document` qui stocke des
  fichiers téléversés.

  Mêmes catégories que `Document` pour que la UI puisse fusionner les
  deux types dans une même liste filtrée. Workflow éditorial calqué
  sur `Articles.Article` (draft → review → published → archived).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:draft, :review, :published, :archived]

  # Réutilise volontairement la liste de catégories du schéma Document
  # — voir Documents.Document. Un PV peut être rédigé en ligne ou
  # téléversé en PDF, et on veut qu'il atterrisse dans la même section
  # côté UI.
  @categories [
    :reglement,
    :pv_ag,
    :pv_conseil,
    :contrat,
    :facture,
    :devis,
    :assurance,
    :charges,
    :plans,
    :autre
  ]

  schema "written_documents" do
    field :title, :string
    field :content, :string, default: ""
    field :category, Ecto.Enum, values: @categories, default: :pv_conseil
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :is_pinned, :boolean, default: false
    field :is_archived, :boolean, default: false
    field :archived_at, :utc_datetime
    field :reviewer_note, :string
    field :published_at, :utc_datetime

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :author, KomunBackend.Accounts.User, foreign_key: :author_id

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def categories, do: @categories

  def changeset(doc, attrs) do
    doc
    |> cast(attrs, [
      :title,
      :content,
      :category,
      :is_pinned,
      :is_archived,
      :archived_at,
      :building_id,
      :author_id
    ])
    |> validate_required([:title, :building_id])
    |> validate_length(:title, max: 200)
  end

  def transition_changeset(doc, attrs) do
    doc
    |> cast(attrs, [:status, :reviewer_note])
    |> validate_required([:status])
    |> maybe_set_published_at()
  end

  defp maybe_set_published_at(changeset) do
    case get_change(changeset, :status) do
      :published ->
        if is_nil(get_field(changeset, :published_at)) do
          put_change(
            changeset,
            :published_at,
            DateTime.utc_now() |> DateTime.truncate(:second)
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
