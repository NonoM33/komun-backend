defmodule KomunBackend.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :building_id, references(:buildings, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :title, :string, null: false
      add :description, :text
      # collecting → residents upload devis
      # voting    → a vote has been started on a chosen devis
      # chosen    → vote closed, devis retained
      # done      → project completed / archived
      add :status, :string, default: "collecting", null: false

      # Nullable pointers set once a vote has been started / winner picked.
      add :chosen_devis_id, :binary_id
      add :vote_id, references(:votes, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:projects, [:building_id])
    create index(:projects, [:status])
  end
end
