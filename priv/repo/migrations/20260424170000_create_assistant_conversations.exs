defmodule KomunBackend.Repo.Migrations.CreateAssistantConversations do
  use Ecto.Migration

  def change do
    create table(:assistant_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false, default: "Nouvelle conversation"

      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :last_message_at, :utc_datetime
      add :message_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:assistant_conversations, [:user_id, :building_id])
    create index(:assistant_conversations, [:building_id])

    alter table(:assistant_messages) do
      add :conversation_id,
          references(:assistant_conversations, type: :binary_id, on_delete: :delete_all)
    end

    create index(:assistant_messages, [:conversation_id, :inserted_at])
  end
end
