defmodule KomunBackend.Repo.Migrations.CreateLots do
  use Ecto.Migration

  def change do
    create table(:lots, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :number, :string, null: false
      add :type, :string, null: false
      add :floor, :integer
      add :area_sqm, :decimal, precision: 8, scale: 2
      add :tantieme, :decimal, precision: 10, scale: 4
      add :is_occupied, :boolean, default: false
      add :building_id, references(:buildings, type: :binary_id, on_delete: :delete_all), null: false
      add :owner_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :tenant_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:lots, [:building_id, :number])
    create index(:lots, [:owner_id])
    create index(:lots, [:tenant_id])
  end
end
