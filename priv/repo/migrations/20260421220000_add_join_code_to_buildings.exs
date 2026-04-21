defmodule KomunBackend.Repo.Migrations.AddJoinCodeToBuildings do
  use Ecto.Migration

  # A short, human-readable code that residents type in on the onboarding
  # screen (e.g. "A1B2C3D4"). 8 uppercase alphanumeric characters keeps the
  # collision space large while staying easy to copy from a wall poster.
  def up do
    alter table(:buildings) do
      add :join_code, :string
    end

    # Backfill any existing rows before we enforce the NOT NULL + uniqueness.
    execute(fn ->
      # Generate an 8-char alphanumeric code for every building that doesn't
      # already have one. Uses upper() on md5(gen_random_uuid()) so it's
      # deterministic via SQL without needing a server round-trip.
      repo().query!(
        """
        UPDATE buildings
        SET join_code = upper(substr(md5(gen_random_uuid()::text), 1, 8))
        WHERE join_code IS NULL
        """,
        []
      )
    end)

    alter table(:buildings) do
      modify :join_code, :string, null: false
    end

    create unique_index(:buildings, [:join_code])
  end

  def down do
    drop index(:buildings, [:join_code])

    alter table(:buildings) do
      remove :join_code
    end
  end
end
