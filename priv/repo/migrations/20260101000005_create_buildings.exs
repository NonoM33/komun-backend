defmodule KomunBackend.Repo.Migrations.CreateBuildings do
  use Ecto.Migration

  def change do
    create table(:buildings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :address, :string, null: false
      add :city, :string, null: false
      add :postal_code, :string, null: false
      add :country, :string, null: false, default: "FR"
      add :lot_count, :integer
      add :construction_year, :integer
      add :cover_url, :string
      add :settings, :map, default: fragment("'{}'::jsonb")
      add :is_active, :boolean, null: false, default: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:buildings, [:organization_id])
    create index(:buildings, [:city])
    create index(:buildings, [:is_active])
  end
end
