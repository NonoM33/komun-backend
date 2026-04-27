defmodule KomunBackend.Repo.Migrations.AddOptionIdToVoteResponses do
  use Ecto.Migration

  def change do
    alter table(:vote_responses) do
      # Nullable: binary votes still use :choice (yes/no/abstain), single_choice
      # votes set :option_id pointing at the chosen vote_options row.
      add :option_id, references(:vote_options, type: :binary_id, on_delete: :delete_all)
      modify :choice, :string, null: true, from: {:string, null: false}
    end

    create index(:vote_responses, [:option_id])
  end
end
