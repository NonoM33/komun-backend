defmodule KomunBackend.Repo.Migrations.CreateAssistantRules do
  use Ecto.Migration

  def change do
    create table(:assistant_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :content, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :position, :integer, null: false, default: 0

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:assistant_rules, [:building_id])
    create index(:assistant_rules, [:building_id, :enabled, :position])
  end
end
