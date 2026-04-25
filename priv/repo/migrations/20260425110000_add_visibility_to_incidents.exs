defmodule KomunBackend.Repo.Migrations.AddVisibilityToIncidents do
  use Ecto.Migration

  def change do
    # Visibility level for incidents:
    # - "standard"     : visible to all building members (default)
    # - "council_only" : visible only to syndic / conseil syndical / super_admin.
    #                    The reporter's identity is never exposed in the
    #                    serialized payload, even to other privileged roles.
    alter table(:incidents) do
      add :visibility, :string, null: false, default: "standard"
    end

    create index(:incidents, [:visibility])
  end
end
