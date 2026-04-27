defmodule KomunBackend.Repo.Migrations.CreateWrittenDocuments do
  use Ecto.Migration

  # Documents rédigés directement dans l'app via l'éditeur Notion-like
  # (typiquement les PV de conseil syndical). Différent de la table
  # `documents` qui stocke des fichiers téléversés. Même workflow
  # éditorial que `articles` : brouillon → relecture → publié.
  def change do
    create table(:written_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false
      add :content, :text, null: false, default: ""
      # Réutilise la même nomenclature que la table `documents` pour que
      # la UI puisse fusionner les deux types dans la même liste filtrée
      # par catégorie.
      add :category, :string, null: false, default: "pv_conseil"
      add :status, :string, null: false, default: "draft"
      add :is_pinned, :boolean, null: false, default: false
      add :is_archived, :boolean, null: false, default: false
      add :archived_at, :utc_datetime
      add :reviewer_note, :text
      add :published_at, :utc_datetime

      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :author_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:written_documents, [:building_id])
    create index(:written_documents, [:building_id, :status])
    create index(:written_documents, [:building_id, :is_archived])
    create index(:written_documents, [:author_id])
    create index(:written_documents, [:category])
    create index(:written_documents, [:published_at])
  end
end
