defmodule KomunBackend.Repo.Migrations.CreateBuildingMembers do
  use Ecto.Migration

  def change do
    create table(:building_members, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :role, :string, null: false
      add :joined_at, :utc_datetime
      add :is_active, :boolean, null: false, default: true
      add :building_id, references(:buildings, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:building_members, [:building_id, :user_id])
    create index(:building_members, [:user_id])
    create index(:building_members, [:role])
  end
end
