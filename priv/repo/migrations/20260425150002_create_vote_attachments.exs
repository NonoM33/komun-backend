defmodule KomunBackend.Repo.Migrations.CreateVoteAttachments do
  use Ecto.Migration

  def change do
    create table(:vote_attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vote_id, references(:votes, type: :binary_id, on_delete: :delete_all), null: false

      # "photo" or "document" — keeps it simple, no need for a polymorphic
      # join. UI groups attachments by kind.
      add :kind, :string, null: false

      add :file_url, :string, null: false
      add :filename, :string
      add :mime_type, :string
      add :file_size_bytes, :bigint
      add :position, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:vote_attachments, [:vote_id, :kind])
  end
end
