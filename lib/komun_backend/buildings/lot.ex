defmodule KomunBackend.Buildings.Lot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lots" do
    field :number, :string
    field :type, Ecto.Enum, values: [:apartment, :parking, :storage, :commercial, :common]
    field :floor, :integer
    field :area_sqm, :decimal
    field :tantieme, :decimal
    field :is_occupied, :boolean, default: false

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :owner, KomunBackend.Accounts.User, foreign_key: :owner_id
    belongs_to :tenant, KomunBackend.Accounts.User, foreign_key: :tenant_id

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:number, :type, :floor, :area_sqm, :tantieme, :is_occupied,
                    :building_id, :owner_id, :tenant_id])
    |> validate_required([:number, :type, :building_id])
  end
end
