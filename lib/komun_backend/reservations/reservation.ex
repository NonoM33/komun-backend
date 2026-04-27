defmodule KomunBackend.Reservations.Reservation do
  @moduledoc """
  Réservation d'un lot du bâtiment — utilisée en V1 pour les places de
  recharge (gratuites, créneaux courts) et en V2 pour la location payante
  des places de parking privées.

  Le champ `kind` distingue les deux usages :
    - `:charging` : place de recharge commune, gratuit, max 4h
    - `:rental`   : location d'une place privée, payante (V2)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_charging_hours 4

  schema "reservations" do
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :status, Ecto.Enum,
      values: [:pending, :confirmed, :cancelled, :completed],
      default: :confirmed
    field :kind, Ecto.Enum, values: [:charging, :rental], default: :charging
    field :notes, :string

    belongs_to :lot, KomunBackend.Buildings.Lot
    belongs_to :user, KomunBackend.Accounts.User
    belongs_to :building, KomunBackend.Buildings.Building

    timestamps(type: :utc_datetime)
  end

  def changeset(reservation, attrs) do
    reservation
    |> cast(attrs, [
      :lot_id,
      :user_id,
      :building_id,
      :starts_at,
      :ends_at,
      :status,
      :kind,
      :notes
    ])
    |> validate_required([:lot_id, :user_id, :building_id, :starts_at, :ends_at])
    |> validate_time_order()
    |> validate_charging_duration()
    |> exclusion_constraint(:starts_at, name: :reservations_no_overlap)
  end

  defp validate_time_order(cs) do
    starts = get_field(cs, :starts_at)
    ends = get_field(cs, :ends_at)

    if starts && ends && DateTime.compare(ends, starts) != :gt do
      add_error(cs, :ends_at, "doit être après le début")
    else
      cs
    end
  end

  # Limite les recharges à 4h consécutives — sinon une seule personne peut
  # squatter la prise toute la journée. Pas de limite côté `:rental` (le
  # propriétaire fixe ses propres créneaux).
  defp validate_charging_duration(cs) do
    kind = get_field(cs, :kind)
    starts = get_field(cs, :starts_at)
    ends = get_field(cs, :ends_at)

    if kind == :charging && starts && ends do
      diff_hours = DateTime.diff(ends, starts, :second) / 3600

      if diff_hours > @max_charging_hours do
        add_error(cs, :ends_at, "une recharge dure au maximum #{@max_charging_hours}h")
      else
        cs
      end
    else
      cs
    end
  end

  def max_charging_hours, do: @max_charging_hours
end
