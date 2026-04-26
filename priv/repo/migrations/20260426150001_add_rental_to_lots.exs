defmodule KomunBackend.Repo.Migrations.AddRentalToLots do
  use Ecto.Migration

  # Permet à un copro propriétaire d'une place (lot type :parking, owner_id
  # set sur l'user) de la mettre en location à l'heure ou au mois. Le prix
  # est en centimes pour éviter les flottants en compta.
  def change do
    alter table(:lots) do
      add :is_rentable, :boolean, null: false, default: false
      add :rental_price_per_hour_cents, :integer
      add :rental_price_per_month_cents, :integer
      add :rental_description, :text
    end

    create index(:lots, [:building_id, :is_rentable],
             where: "is_rentable = true",
             name: :lots_rentable_index)
  end
end
