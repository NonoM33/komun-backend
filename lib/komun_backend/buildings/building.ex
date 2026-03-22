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

    belongs_to :organization, KomunBackend.Organizations.Organization
    has_many :lots, KomunBackend.Buildings.Lot
    has_many :members, KomunBackend.Buildings.BuildingMember
    has_many :incidents, KomunBackend.Incidents.Incident
    has_many :announcements, KomunBackend.Announcements.Announcement

    timestamps(type: :utc_datetime)
  end

  def changeset(building, attrs) do
    building
    |> cast(attrs, [:name, :address, :city, :postal_code, :country,
                    :lot_count, :construction_year, :cover_url, :settings, :organization_id])
    |> validate_required([:name, :address, :city, :postal_code, :organization_id])
    |> validate_number(:construction_year, greater_than: 1800, less_than_or_equal_to: 2030)
  end

  # Admin changeset — organization_id optional (super_admin creates standalone buildings)
  def admin_changeset(building, attrs) do
    building
    |> cast(attrs, [:name, :address, :city, :postal_code, :country,
                    :lot_count, :construction_year, :cover_url, :settings, :organization_id])
    |> validate_required([:name, :address, :city, :postal_code])
    |> validate_number(:construction_year, greater_than: 1800, less_than_or_equal_to: 2030)
  end
end
