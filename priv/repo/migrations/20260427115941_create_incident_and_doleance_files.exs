defmodule KomunBackend.Repo.Migrations.CreateIncidentAndDoleanceFiles do
  use Ecto.Migration

  # Pièces jointes pour les incidents et les doléances. On reprend
  # exactement le même schéma que `diligence_files` (cf. migration
  # 20260425220000) pour garder la même UX côté front et la même
  # stratégie de stockage local sur disque.
  def change do
    create table(:incident_files, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :incident_id,
          references(:incidents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :uploaded_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      # photo | document — auto-déduit du mime côté controller mais
      # stocké pour pouvoir filtrer / grouper plus tard sans relire le
      # mime de chaque ligne.
      add :kind, :string, null: false

      add :filename, :string, null: false
      add :file_url, :string, null: false
      add :file_size_bytes, :integer
      add :mime_type, :string

      timestamps(type: :utc_datetime)
    end

    create index(:incident_files, [:incident_id])

    create table(:doleance_files, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :doleance_id,
          references(:doleances, type: :binary_id, on_delete: :delete_all),
          null: false

      add :uploaded_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :kind, :string, null: false

      add :filename, :string, null: false
      add :file_url, :string, null: false
      add :file_size_bytes, :integer
      add :mime_type, :string

      timestamps(type: :utc_datetime)
    end

    create index(:doleance_files, [:doleance_id])
  end
end
