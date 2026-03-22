defmodule KomunBackend.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :filename, :string
      add :file_url, :string
      add :category, :string, default: "autre"
      add :file_size_bytes, :integer
      add :mime_type, :string
      add :is_public, :boolean, default: true
      add :building_id, references(:buildings, type: :binary_id, on_delete: :delete_all), null: false
      add :uploaded_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:documents, [:building_id])
    create index(:documents, [:category])
  end
end
