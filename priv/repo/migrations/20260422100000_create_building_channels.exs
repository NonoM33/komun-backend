defmodule KomunBackend.Repo.Migrations.CreateBuildingChannels do
  use Ecto.Migration

  def change do
    create table(:building_channels, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :description, :string
      add :visibility, :string, null: false, default: "public"
      add :is_readonly, :boolean, null: false, default: false

      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:building_channels, [:building_id])
    create unique_index(:building_channels, [:building_id, :name])
  end
end
