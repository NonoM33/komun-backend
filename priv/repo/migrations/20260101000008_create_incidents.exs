defmodule KomunBackend.Repo.Migrations.CreateIncidents do
  use Ecto.Migration

  def change do
    create table(:incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false
      add :description, :text, null: false
      add :category, :string, null: false
      add :severity, :string, null: false, default: "medium"
      add :status, :string, null: false, default: "open"
      add :photo_urls, {:array, :string}, default: []
      add :location, :string
      add :lot_number, :string
      add :resolution_note, :text
      add :resolved_at, :utc_datetime
      add :building_id, references(:buildings, type: :binary_id, on_delete: :delete_all), null: false
      add :reporter_id, references(:users, type: :binary_id, on_delete: :nilify_all), null: false
      add :assignee_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:incidents, [:building_id])
    create index(:incidents, [:reporter_id])
    create index(:incidents, [:assignee_id])
    create index(:incidents, [:status])
    create index(:incidents, [:severity])
    create index(:incidents, [:inserted_at])
  end
end
