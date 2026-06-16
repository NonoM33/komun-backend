defmodule KomunBackend.CommonResources.Resource do
  @moduledoc """
  Une ressource commune réservable du bâtiment : ascenseur (cas typique
  V1, déménagement avec protection 48h à l'avance), salle commune,
  parking visiteur, local vélos, toit-terrasse…

  Distinct de `KomunBackend.Reservations` qui ne couvre QUE les places
  de recharge (réservation par lot, payante en V2). Ici on parle d'un
  bien collectif que tout résident peut demander à utiliser
  ponctuellement, sous réserve d'une validation par le conseil syndical.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds [:elevator, :common_room, :parking, :bike_room, :rooftop, :other]

  schema "common_resources" do
    field :name, :string
    field :description, :string
    field :kind, Ecto.Enum, values: @kinds, default: :other
    field :advance_notice_hours, :integer, default: 48
    field :max_duration_hours, :integer, default: 8
    field :allowed_hours_start, :integer, default: 8
    field :allowed_hours_end, :integer, default: 20
    field :exclusive, :boolean, default: true
    field :active, :boolean, default: true

    belongs_to :building, KomunBackend.Buildings.Building

    has_many :bookings, KomunBackend.CommonResources.Booking,
      foreign_key: :common_resource_id

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @cast_fields ~w(
    name description kind building_id
    advance_notice_hours max_duration_hours
    allowed_hours_start allowed_hours_end
    exclusive active
  )a

  @doc """
  Changeset à la création — `building_id` est requis (toujours dérivé
  du contexte d'appel, jamais du payload utilisateur côté admin route).
  """
  def create_changeset(resource, attrs) do
    resource
    |> cast(attrs, @cast_fields)
    |> validate_required([:name, :building_id, :kind])
    |> common_validations()
    |> assoc_constraint(:building)
  end

  @doc """
  Changeset d'édition par l'admin (syndic / super_admin). On autorise
  tous les champs sauf `building_id` (ressource non transférable).
  """
  def update_changeset(resource, attrs) do
    resource
    |> cast(attrs, @cast_fields -- [:building_id])
    |> validate_required([:name, :kind])
    |> common_validations()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_length(:name, min: 2, max: 100)
    |> validate_length(:description, max: 1000)
    |> validate_number(:advance_notice_hours, greater_than_or_equal_to: 0, less_than_or_equal_to: 720)
    |> validate_number(:max_duration_hours, greater_than: 0, less_than_or_equal_to: 168)
    |> validate_number(:allowed_hours_start, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:allowed_hours_end, greater_than_or_equal_to: 1, less_than_or_equal_to: 24)
    |> validate_hours_window()
  end

  # `allowed_hours_end` doit être strictement > `allowed_hours_start`.
  # On ne gère pas (encore) les fenêtres qui chevauchent minuit (ex.
  # 22h→6h) — pas de cas d'usage V1, on ajoutera si besoin.
  defp validate_hours_window(changeset) do
    s = get_field(changeset, :allowed_hours_start)
    e = get_field(changeset, :allowed_hours_end)

    if is_integer(s) and is_integer(e) and e <= s do
      add_error(changeset, :allowed_hours_end,
        "doit être strictement supérieure à allowed_hours_start")
    else
      changeset
    end
  end
end
