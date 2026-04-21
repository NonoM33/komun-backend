defmodule KomunBackend.Repo.Migrations.CreateAssistantMessages do
  use Ecto.Migration

  def change do
    create table(:assistant_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :question, :text, null: false
      add :answer, :text
      add :model, :string
      add :tokens_prompt, :integer
      add :tokens_completion, :integer
      # :ok | :failed | :rate_limited (stored as-is to avoid a migration every
      # time we add a value)
      add :status, :string, null: false, default: "ok"
      add :error, :text

      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create index(:assistant_messages, [:building_id])
    create index(:assistant_messages, [:user_id, :inserted_at])

    alter table(:users) do
      add :last_chat_at, :utc_datetime
    end
  end
end
