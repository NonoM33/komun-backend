defmodule KomunBackend.Repo.Migrations.CreateVotes do
  use Ecto.Migration

  def change do
    create table(:votes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :building_id, references(:buildings, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :title, :string, null: false
      add :description, :text
      add :status, :string, default: "open", null: false
      add :ends_at, :utc_datetime
      add :is_anonymous, :boolean, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:votes, [:building_id])
    create index(:votes, [:status])
  end
end
