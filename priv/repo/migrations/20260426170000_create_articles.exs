defmodule KomunBackend.Repo.Migrations.CreateArticles do
  use Ecto.Migration

  # Articles éditoriaux pour la copro (actu, guides, vie de copro, …),
  # rédigés via l'éditeur Notion-like côté web_v2. Workflow brouillon →
  # relecture → publié → archivé. Seuls les articles `published` sont
  # visibles des résidents lambda ; le CS voit tous ses brouillons.
  def change do
    create table(:articles, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false
      add :excerpt, :text
      # Contenu HTML produit par TipTap. On stocke en `text` plutôt que
      # `string` car les articles peuvent être longs.
      add :content, :text, null: false, default: ""
      add :category, :string, null: false, default: "actualite"
      add :status, :string, null: false, default: "draft"
      add :is_pinned, :boolean, null: false, default: false
      add :cover_url, :string
      add :reviewer_note, :text
      add :published_at, :utc_datetime

      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      # On garde l'auteur même si le user est supprimé : l'article reste
      # publié, juste sans signature.
      add :author_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:articles, [:building_id])
    create index(:articles, [:building_id, :status])
    create index(:articles, [:author_id])
    create index(:articles, [:is_pinned])
    create index(:articles, [:published_at])
  end
end
