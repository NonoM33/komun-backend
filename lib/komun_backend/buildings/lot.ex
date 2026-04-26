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

    # Place de recharge VE commune — flaggée par le syndic, réservable
    # par tous les membres du bâtiment via la feature parking V1.
    field :is_charging_spot, :boolean, default: false

    # Location payante d'une place privée (Phase 2). Le proprio (owner_id)
    # déclare son tarif horaire/mensuel et la description publique.
    # Nécessite que l'owner ait fait son onboarding Stripe Connect.
    field :is_rentable, :boolean, default: false
    field :rental_price_per_hour_cents, :integer
    field :rental_price_per_month_cents, :integer
    field :rental_description, :string

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :owner, KomunBackend.Accounts.User, foreign_key: :owner_id
    belongs_to :tenant, KomunBackend.Accounts.User, foreign_key: :tenant_id

    timestamps(type: :utc_datetime)
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [:number, :type, :floor, :area_sqm, :tantieme, :is_occupied,
                    :is_charging_spot,
                    :is_rentable, :rental_price_per_hour_cents,
                    :rental_price_per_month_cents, :rental_description,
                    :building_id, :owner_id, :tenant_id])
    |> validate_required([:number, :type, :building_id])
  end
end
