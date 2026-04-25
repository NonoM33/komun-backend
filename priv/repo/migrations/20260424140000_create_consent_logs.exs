defmodule KomunBackend.Repo.Migrations.CreateConsentLogs do
  use Ecto.Migration

  def change do
    create table(:consent_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Nullable: logs may come from anonymous visitors (pre-signup) or
      # authenticated users. At least one of user_id / visitor_id must be set.
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :nilify_all)
      add :visitor_id, :string

      add :essential, :boolean, default: true, null: false
      add :analytics, :boolean, default: false, null: false
      add :session_replay, :boolean, default: false, null: false
      add :marketing, :boolean, default: false, null: false

      # banner_all | banner_essential | banner_custom | settings | withdraw
      add :source, :string, null: false
      add :policy_version, :string, null: false
      add :ip_address, :string
      add :user_agent, :string

      timestamps(type: :utc_datetime)
    end

    create index(:consent_logs, [:user_id, :inserted_at])
    create index(:consent_logs, [:visitor_id, :inserted_at])
    create index(:consent_logs, [:inserted_at])
  end
end
