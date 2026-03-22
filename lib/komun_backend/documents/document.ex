defmodule KomunBackend.Documents.Document do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "documents" do
    field :title, :string
    field :filename, :string
    field :file_url, :string
    field :category, Ecto.Enum,
      values: [:reglement, :pv_ag, :contrat, :facture, :devis, :assurance, :autre],
      default: :autre
    field :file_size_bytes, :integer
    field :mime_type, :string
    field :is_public, :boolean, default: true

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :uploaded_by, KomunBackend.Accounts.User, foreign_key: :uploaded_by_id

    timestamps(type: :utc_datetime)
  end

  def changeset(doc, attrs) do
    doc
    |> cast(attrs, [:title, :filename, :file_url, :category, :file_size_bytes,
                    :mime_type, :is_public, :building_id, :uploaded_by_id])
    |> validate_required([:title, :building_id])
  end
end
