defmodule KomunBackend.Buildings.Building do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "buildings" do
    field :name, :string
    field :address, :string
    field :city, :string
    field :postal_code, :string
    field :country, :string, default: "FR"
    field :lot_count, :integer
    field :construction_year, :integer
    field :cover_url, :string
    field :settings, :map, default: %{}
    field :is_active, :boolean, default: true
    field :join_code, :string

    belongs_to :organization, KomunBackend.Organizations.Organization
    belongs_to :residence, KomunBackend.Residences.Residence
    has_many :lots, KomunBackend.Buildings.Lot
    has_many :members, KomunBackend.Buildings.BuildingMember
    has_many :incidents, KomunBackend.Incidents.Incident
    has_many :announcements, KomunBackend.Announcements.Announcement

    timestamps(type: :utc_datetime)
  end

  @cast_fields ~w(name address city postal_code country lot_count construction_year
                  cover_url settings join_code organization_id residence_id)a

  def changeset(building, attrs) do
    building
    |> cast(attrs, @cast_fields)
    |> validate_required([:name, :address, :city, :postal_code, :residence_id])
    |> validate_number(:construction_year, greater_than: 1800, less_than_or_equal_to: 2030)
    |> unique_constraint(:join_code)
  end

  # Admin changeset — organization_id optional (super_admin creates standalone buildings)
  def admin_changeset(building, attrs) do
    building
    |> cast(attrs, @cast_fields)
    |> validate_required([:name, :address, :city, :postal_code])
    |> validate_number(:construction_year, greater_than: 1800, less_than_or_equal_to: 2030)
    |> unique_constraint(:join_code)
  end
end
