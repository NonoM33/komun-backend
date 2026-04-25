defmodule KomunBackend.Repo.Migrations.CreateDiligences do
  use Ecto.Migration

  def change do
    create table(:diligences, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :linked_incident_id,
          references(:incidents, type: :binary_id, on_delete: :nilify_all)

      add :title, :string, null: false
      add :description, :text

      # open       → dossier ouvert, étapes en cours
      # closed     → résolu / clos sans escalade judiciaire
      # escalated  → action judiciaire en cours / engagée
      add :status, :string, null: false, default: "open"

      # copro_owner | tenant | unknown — type de la personne à l'origine
      # du trouble. Conditionne la procédure (cf. étape 3 du plan).
      add :source_type, :string

      # Identifiant lisible du voisin gênant (« M. Untel, lot 14 »).
      # PII : ne jamais l'exposer aux non-CS, ne jamais le logger en clair.
      add :source_label, :string

      # Courriers générés (texte plain), nil tant que pas généré.
      # On stocke en colonne pour pouvoir versionner / rejouer la génération.
      add :saisine_syndic_letter, :text
      add :mise_en_demeure_letter, :text

      timestamps(type: :utc_datetime)
    end

    create index(:diligences, [:building_id])
    create index(:diligences, [:linked_incident_id])
    create index(:diligences, [:building_id, :status])

    create table(:diligence_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :diligence_id,
          references(:diligences, type: :binary_id, on_delete: :delete_all),
          null: false

      # 1..9 — voir KomunBackend.Diligences.Steps pour le mapping clé/titre.
      # Contrainte d'unicité (diligence_id, step_number) plus bas pour
      # garantir qu'on ne crée pas deux fois la même étape.
      add :step_number, :integer, null: false

      # pending | in_progress | completed | skipped
      add :status, :string, null: false, default: "pending"
      add :notes, :text
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:diligence_steps, [:diligence_id, :step_number])
    create index(:diligence_steps, [:status])

    create table(:diligence_files, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :diligence_id,
          references(:diligences, type: :binary_id, on_delete: :delete_all),
          null: false

      # Rattachement optionnel à une étape précise (pratique pour
      # afficher les preuves regroupées sous l'étape 2 « Collecter les
      # preuves »). Nil = pièce non rattachée.
      add :step_number, :integer

      add :uploaded_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      # journal | attestation_cerfa | photo | constat_huissier | autre
      add :kind, :string, null: false

      add :filename, :string, null: false
      add :file_url, :string, null: false
      add :file_size_bytes, :integer
      add :mime_type, :string

      timestamps(type: :utc_datetime)
    end

    create index(:diligence_files, [:diligence_id])
    create index(:diligence_files, [:diligence_id, :step_number])
  end
end
