defmodule KomunBackend.Archives.ArchivedCouncilVote do
  @moduledoc """
  Snapshot read-only d'un vote du conseil syndical tenu sur l'ancienne
  stack Rails (`council_votes`). Importé via un dump JSON côté admin.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "archived_council_votes" do
    field :legacy_id, :string
    field :title, :string
    field :description, :string
    field :vote_type, :string
    field :status, :string
    field :anonymous, :boolean, default: false
    field :options, {:array, :map}, default: []
    field :total_votes, :integer, default: 0
    field :winning_option_text, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :closed_at, :utc_datetime
    field :legacy_created_at, :utc_datetime

    belongs_to :residence, KomunBackend.Residences.Residence

    timestamps(type: :utc_datetime)
  end

  @cast_fields ~w(legacy_id title description vote_type status anonymous
                  options total_votes winning_option_text starts_at ends_at
                  closed_at legacy_created_at residence_id)a

  def changeset(archived, attrs) do
    archived
    |> cast(attrs, @cast_fields)
    |> validate_required([:legacy_id, :title, :legacy_created_at])
    |> unique_constraint(:legacy_id)
  end
end
