defmodule KomunBackend.Repo.Migrations.AddPinnedContentToDocuments do
  use Ecto.Migration

  # Pinned documents show at the top of the residence's document list.
  # Content text is the extracted/pasted plain text used by the AI chatbot
  # to ground its answers (règlement, PV de conseil, etc.).
  def change do
    alter table(:documents) do
      add :is_pinned, :boolean, null: false, default: false
      add :content_text, :text
    end

    create index(:documents, [:building_id, :category])
    create index(:documents, [:is_pinned])
  end
end
