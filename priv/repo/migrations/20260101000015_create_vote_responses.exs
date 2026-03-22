defmodule KomunBackend.Repo.Migrations.CreateVoteResponses do
  use Ecto.Migration

  def change do
    create table(:vote_responses, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vote_id, references(:votes, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :choice, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:vote_responses, [:vote_id])
    create unique_index(:vote_responses, [:vote_id, :user_id])
  end
end
