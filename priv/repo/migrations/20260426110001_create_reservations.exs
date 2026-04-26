defmodule KomunBackend.Repo.Migrations.CreateReservations do
  use Ecto.Migration

  # Réservations sur des lots du bâtiment (places de recharge en V1,
  # locations payantes en V2). Le `kind` distingue les deux usages.
  #
  # Pas de chevauchement possible sur le même lot : on s'appuie sur
  # une `EXCLUDE` constraint Postgres avec un `tsrange` calculé. Plus
  # robuste qu'un check applicatif (impossible à contourner même par
  # une race condition sur deux requêtes concurrentes).
  def change do
    execute("CREATE EXTENSION IF NOT EXISTS btree_gist", "")

    create table(:reservations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :lot_id, references(:lots, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all),
          null: false

      add :building_id, references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false

      add :status, :string, null: false, default: "confirmed"
      add :kind, :string, null: false, default: "charging"
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:reservations, [:lot_id, :starts_at])
    create index(:reservations, [:user_id])
    create index(:reservations, [:building_id, :starts_at])
    create index(:reservations, [:status])

    # Sanity check : `ends_at` doit être strictement après `starts_at`.
    create constraint(:reservations, :reservation_time_order,
             check: "ends_at > starts_at")

    # Anti-overlap : aucune autre réservation `:confirmed` ne peut couvrir
    # le même créneau sur le même lot. On utilise tsrange (et non
    # tstzrange) parce que :utc_datetime mappe sur `timestamp without
    # time zone` côté Postgres, et tstzrange n'est pas IMMUTABLE sur ce
    # type d'entrée (refusé par EXCLUDE USING gist). tsrange est
    # IMMUTABLE et tout aussi correct vu qu'on stocke déjà tout en UTC.
    execute(
      """
      ALTER TABLE reservations ADD CONSTRAINT reservations_no_overlap EXCLUDE USING gist (
        lot_id WITH =,
        tsrange(starts_at, ends_at, '[)') WITH &&
      ) WHERE (status = 'confirmed')
      """,
      """
      ALTER TABLE reservations DROP CONSTRAINT reservations_no_overlap
      """
    )
  end
end
