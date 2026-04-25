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

  # IMPORTANT : `join_code` ne fait PAS partie des champs castables sur
  # les changesets d'édition. Le code a été communiqué aux copropriétaires
  # hors de l'appli — le changer silencieusement casse l'onboarding pour
  # tous les voisins. Voir CLAUDE.md à la racine du repo frontend pour la
  # règle complète. Les seules écritures légitimes du champ passent par
  # `initial_changeset/2` (création d'un bâtiment neuf).
  @edit_fields ~w(name address city postal_code country lot_count construction_year
                  cover_url settings organization_id residence_id)a

  @create_fields [:join_code | @edit_fields]

  def changeset(building, attrs) do
    building
    |> cast(attrs, @edit_fields)
    |> validate_required([:name, :address, :city, :postal_code, :residence_id])
    |> validate_number(:construction_year, greater_than: 1800, less_than_or_equal_to: 2030)
  end

  # Admin changeset — organization_id optional (super_admin creates standalone buildings)
  def admin_changeset(building, attrs) do
    building
    |> cast(attrs, @edit_fields)
    |> validate_required([:name, :address, :city, :postal_code])
    |> validate_number(:construction_year, greater_than: 1800, less_than_or_equal_to: 2030)
  end

  @doc """
  Changeset utilisé uniquement à la CRÉATION d'un bâtiment neuf (accepte
  et exige `:join_code`). Ne PAS utiliser pour une édition.
  """
  def initial_changeset(building, attrs) do
    building
    |> cast(attrs, @create_fields)
    |> validate_required([:name, :address, :city, :postal_code, :join_code])
    |> validate_number(:construction_year, greater_than: 1800, less_than_or_equal_to: 2030)
    |> unique_constraint(:join_code)
  end
end
