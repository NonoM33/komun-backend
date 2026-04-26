defmodule KomunBackend.Repo.Migrations.AddExternalUrlToVoteOptions do
  use Ecto.Migration

  def change do
    alter table(:vote_options) do
      add :external_url, :string, size: 2048
    end
  end
end
