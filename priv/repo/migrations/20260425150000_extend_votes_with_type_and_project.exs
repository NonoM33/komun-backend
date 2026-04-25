defmodule KomunBackend.Repo.Migrations.ExtendVotesWithTypeAndProject do
  use Ecto.Migration

  def change do
    alter table(:votes) do
      add :vote_type, :string, default: "binary", null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:votes, [:project_id])
  end
end
