defmodule KomunBackend.Buildings.BuildingMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "building_members" do
    field :role, Ecto.Enum,
      values: [:president_cs, :membre_cs, :coproprietaire, :locataire, :gardien, :prestataire]
    field :joined_at, :utc_datetime
    field :is_active, :boolean, default: true

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :user, KomunBackend.Accounts.User
    belongs_to :primary_lot, KomunBackend.Buildings.Lot, foreign_key: :primary_lot_id
    has_many :lots, KomunBackend.Buildings.Lot, foreign_key: :owner_id, references: :user_id

    timestamps(type: :utc_datetime)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:role, :joined_at, :is_active, :building_id, :user_id, :primary_lot_id])
    |> validate_required([:role, :building_id, :user_id])
    |> unique_constraint([:building_id, :user_id])
  end
end
