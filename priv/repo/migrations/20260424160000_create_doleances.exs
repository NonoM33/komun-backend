defmodule KomunBackend.Repo.Migrations.CreateDoleances do
  use Ecto.Migration

  def change do
    create table(:doleances, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :title, :string, null: false
      add :description, :text, null: false
      add :category, :string, null: false, default: "autre"
      add :severity, :string, null: false, default: "medium"
      add :status, :string, null: false, default: "open"

      # Preuves attachées par l'auteur (URLs hébergées ailleurs). Les
      # co-signataires ajoutent leurs propres preuves sur doleance_supports.
      add :photo_urls, {:array, :string}, null: false, default: []
      add :document_urls, {:array, :string}, null: false, default: []

      # Cible visée par la plainte : syndic, constructeur, assurance…
      # `target_name` est libre pour qu'on puisse inscrire "Bouygues
      # Immobilier" ou "Cabinet X" sans dépendre d'un référentiel.
      add :target_kind, :string
      add :target_name, :string
      add :target_email, :string

      # Dossier généré par l'IA : courrier formel + suggestions d'experts
      # à contacter (huissier, bureau d'études, avocat, …).
      add :ai_letter, :text
      add :ai_letter_generated_at, :utc_datetime
      add :ai_expert_suggestions, :text
      add :ai_suggestions_generated_at, :utc_datetime
      add :ai_model, :string

      add :escalated_at, :utc_datetime
      add :resolved_at, :utc_datetime
      add :resolution_note, :text

      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :author_id,
          references(:users, type: :binary_id, on_delete: :nilify_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create index(:doleances, [:building_id])
    create index(:doleances, [:author_id])
    create index(:doleances, [:status])

    # Co-signatures : chaque voisin qui se joint à la plainte peut ajouter
    # son témoignage (ex : "même chose sur ma 308 le 12 mars") et ses
    # propres preuves.
    create table(:doleance_supports, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :comment, :text
      add :photo_urls, {:array, :string}, null: false, default: []

      add :doleance_id,
          references(:doleances, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    # Un utilisateur co-signe une doléance au plus une fois. Pour en
    # ajouter d'autres témoignages, il édite sa co-signature.
    create unique_index(:doleance_supports, [:doleance_id, :user_id])
    create index(:doleance_supports, [:user_id])
  end
end
