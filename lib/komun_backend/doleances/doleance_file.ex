defmodule KomunBackend.Doleances.DoleanceFile do
  @moduledoc """
  Pièce jointe attachée à une doléance (photo, devis, PV, facture…).
  Aligné sur `IncidentFile` et `DiligenceFile`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds [:photo, :document]

  schema "doleance_files" do
    field :kind, Ecto.Enum, values: @kinds
    field :filename, :string
    field :file_url, :string
    field :file_size_bytes, :integer
    field :mime_type, :string

    belongs_to :doleance, KomunBackend.Doleances.Doleance
    belongs_to :uploaded_by, KomunBackend.Accounts.User, foreign_key: :uploaded_by_id

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(file, attrs) do
    file
    |> cast(attrs, [
      :doleance_id,
      :uploaded_by_id,
      :kind,
      :filename,
      :file_url,
      :file_size_bytes,
      :mime_type
    ])
    |> validate_required([:doleance_id, :kind, :filename, :file_url])
    |> validate_length(:filename, max: 255)
    |> assoc_constraint(:doleance)
  end
end
