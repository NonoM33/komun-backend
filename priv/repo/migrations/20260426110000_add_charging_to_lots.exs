defmodule KomunBackend.Repo.Migrations.AddChargingToLots do
  use Ecto.Migration

  # Flag les places communes équipées d'une prise (utilisées en V1 pour
  # la réservation de créneaux de recharge VE — gratuit, premier arrivé
  # premier servi). Le syndic flagge ces places via /admin/charging-spots.
  def change do
    alter table(:lots) do
      add :is_charging_spot, :boolean, null: false, default: false
    end

    create index(:lots, [:building_id, :is_charging_spot],
             where: "is_charging_spot = true",
             name: :lots_charging_spots_index)
  end
end
