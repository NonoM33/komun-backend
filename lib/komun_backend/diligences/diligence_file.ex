defmodule KomunBackend.Diligences.DiligenceFile do
  @moduledoc """
  Pièce attachée à une diligence (journal daté de nuisances,
  attestation CERFA n°11527*03, photo, constat de commissaire de
  justice…). En PR#1, ce schéma est seulement déclaré pour que le
  has_many côté `Diligence` charge — l'endpoint d'upload arrive
  en PR#2.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds [:journal, :attestation_cerfa, :photo, :constat_huissier, :autre]

  schema "diligence_files" do
    field :step_number, :integer
    field :kind, Ecto.Enum, values: @kinds
    field :filename, :string
    field :file_url, :string
    field :file_size_bytes, :integer
    field :mime_type, :string

    belongs_to :diligence, KomunBackend.Diligences.Diligence
    belongs_to :uploaded_by, KomunBackend.Accounts.User, foreign_key: :uploaded_by_id

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(file, attrs) do
    file
    |> cast(attrs, [
      :diligence_id,
      :step_number,
      :uploaded_by_id,
      :kind,
      :filename,
      :file_url,
      :file_size_bytes,
      :mime_type
    ])
    |> validate_required([:diligence_id, :kind, :filename, :file_url])
    |> validate_length(:filename, max: 255)
    |> assoc_constraint(:diligence)
  end
end
