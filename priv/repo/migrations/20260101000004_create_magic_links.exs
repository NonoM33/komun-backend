defmodule KomunBackend.Repo.Migrations.CreateMagicLinks do
  use Ecto.Migration

  def change do
    create table(:magic_links, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :token_hash, :string, null: false
      add :email, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:magic_links, [:token_hash])
    create index(:magic_links, [:email])
    create index(:magic_links, [:expires_at])
  end
end
