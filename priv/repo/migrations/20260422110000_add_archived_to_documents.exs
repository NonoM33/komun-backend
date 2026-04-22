defmodule KomunBackend.Repo.Migrations.AddArchivedToDocuments do
  use Ecto.Migration

  # Syndic / conseil may want to keep a historical document but hide it
  # from residents and from the AI context. Archive is the soft-delete
  # mirror of is_public=false but kept semantic so we can distinguish
  # "jamais publié" (is_public=false) from "retiré après coup".
  def change do
    alter table(:documents) do
      add :is_archived, :boolean, null: false, default: false
      add :archived_at, :utc_datetime
    end

    create index(:documents, [:building_id, :is_archived])
  end
end
