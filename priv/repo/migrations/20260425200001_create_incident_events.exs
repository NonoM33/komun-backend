defmodule KomunBackend.Repo.Migrations.CreateIncidentEvents do
  use Ecto.Migration

  def up do
    create table(:incident_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}

      add :incident_id,
          references(:incidents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :actor_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :inserted_at, :utc_datetime, null: false
    end

    create index(:incident_events, [:incident_id, :inserted_at])
    create index(:incident_events, [:actor_id])

    # Backfill rétrospectif : pour que les anciens dossiers ne paraissent
    # pas vides au lancement, on injecte un event :created par incident
    # existant (acteur = reporter, daté = inserted_at de l'incident) et
    # un :comment_added par commentaire existant. gen_random_uuid() vient
    # de pgcrypto, dispo par défaut sur PG 13+ et déjà utilisé par les
    # migrations existantes.
    execute(~S"""
    INSERT INTO incident_events (id, event_type, payload, incident_id, actor_id, inserted_at)
    SELECT
      gen_random_uuid(),
      'created',
      '{}'::jsonb,
      i.id,
      i.reporter_id,
      i.inserted_at
    FROM incidents i
    """)

    execute(~S"""
    INSERT INTO incident_events (id, event_type, payload, incident_id, actor_id, inserted_at)
    SELECT
      gen_random_uuid(),
      'comment_added',
      jsonb_build_object('comment_id', c.id::text, 'is_internal', c.is_internal),
      c.incident_id,
      c.author_id,
      c.inserted_at
    FROM incident_comments c
    """)
  end

  def down do
    drop index(:incident_events, [:actor_id])
    drop index(:incident_events, [:incident_id, :inserted_at])
    drop table(:incident_events)
  end
end
