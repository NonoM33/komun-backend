defmodule KomunBackend.Repo.Migrations.CreateDoleanceEvents do
  use Ecto.Migration

  def change do
    create table(:doleance_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :event_type, :string, null: false
      add :payload, :map, default: %{}

      add :doleance_id,
          references(:doleances, type: :binary_id, on_delete: :delete_all),
          null: false

      add :actor_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:doleance_events, [:doleance_id])
    create index(:doleance_events, [:actor_id])
    create index(:doleance_events, [:inserted_at])

    # Backfill : un événement :created pour chaque doléance existante,
    # afin que la timeline ne soit jamais vide à l'activation.
    execute """
    INSERT INTO doleance_events (id, event_type, doleance_id, actor_id, payload, inserted_at)
    SELECT
      gen_random_uuid(),
      'created',
      d.id,
      d.author_id,
      '{}',
      d.inserted_at
    FROM doleances d
    ON CONFLICT DO NOTHING
    """,
    "DELETE FROM doleance_events WHERE event_type = 'created'"

    # Backfill : un événement :escalated pour les doléances déjà escaladées.
    execute """
    INSERT INTO doleance_events (id, event_type, doleance_id, actor_id, payload, inserted_at)
    SELECT
      gen_random_uuid(),
      'escalated',
      d.id,
      d.author_id,
      '{}',
      COALESCE(d.escalated_at, d.updated_at)
    FROM doleances d
    WHERE d.escalated_at IS NOT NULL
    ON CONFLICT DO NOTHING
    """,
    "DELETE FROM doleance_events WHERE event_type = 'escalated'"

    # Backfill : un événement :resolved pour les doléances déjà résolues.
    execute """
    INSERT INTO doleance_events (id, event_type, doleance_id, actor_id, payload, inserted_at)
    SELECT
      gen_random_uuid(),
      'resolved',
      d.id,
      d.author_id,
      json_build_object('resolution_note', COALESCE(d.resolution_note, ''))::jsonb,
      COALESCE(d.resolved_at, d.updated_at)
    FROM doleances d
    WHERE d.resolved_at IS NOT NULL
    ON CONFLICT DO NOTHING
    """,
    "DELETE FROM doleance_events WHERE event_type = 'resolved'"
  end
end
