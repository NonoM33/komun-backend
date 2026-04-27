defmodule KomunBackend.Repo.Migrations.CreateVoteOptions do
  use Ecto.Migration

  def change do
    create table(:vote_options, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vote_id, references(:votes, type: :binary_id, on_delete: :delete_all), null: false
      add :devis_id, references(:project_devis, type: :binary_id, on_delete: :nilify_all)

      add :label, :string, null: false
      add :position, :integer, default: 0, null: false
      add :is_recommended, :boolean, default: false, null: false

      add :attachment_url, :string
      add :attachment_filename, :string
      add :attachment_mime_type, :string
      add :attachment_size_bytes, :bigint

      timestamps(type: :utc_datetime)
    end

    create index(:vote_options, [:vote_id])
    create index(:vote_options, [:devis_id])
  end
end
