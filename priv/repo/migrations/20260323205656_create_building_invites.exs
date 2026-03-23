defmodule KomunBackend.Repo.Migrations.CreateBuildingInvites do
  use Ecto.Migration

  def change do
    create table(:building_invites, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :token, :string, null: false
      add :role, :string, null: false, default: "coproprietaire"
      add :is_active, :boolean, null: false, default: true
      add :used_count, :integer, null: false, default: 0
      add :max_uses, :integer
      add :expires_at, :utc_datetime

      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:building_invites, [:token])
    create index(:building_invites, [:building_id])
  end
end
