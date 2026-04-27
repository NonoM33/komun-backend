defmodule KomunBackend.Repo.Migrations.AddFollowUpFieldsToIncidents do
  use Ecto.Migration

  def up do
    alter table(:incidents) do
      add :last_follow_up_at, :utc_datetime
      add :last_action_at, :utc_datetime
      add :follow_up_count, :integer, null: false, default: 0

      add :linked_doleance_id,
          references(:doleances, type: :binary_id, on_delete: :nilify_all)
    end

    execute(~S"""
    UPDATE incidents
       SET last_action_at = COALESCE(updated_at, inserted_at)
     WHERE last_action_at IS NULL
    """)

    create index(:incidents, [:building_id, :status, :last_action_at])
    create index(:incidents, [:linked_doleance_id])
  end

  def down do
    drop index(:incidents, [:linked_doleance_id])
    drop index(:incidents, [:building_id, :status, :last_action_at])

    alter table(:incidents) do
      remove :linked_doleance_id
      remove :follow_up_count
      remove :last_action_at
      remove :last_follow_up_at
    end
  end
end
