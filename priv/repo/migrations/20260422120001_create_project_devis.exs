defmodule KomunBackend.Repo.Migrations.CreateProjectDevis do
  use Ecto.Migration

  def change do
    create table(:project_devis, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :uploaded_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :vendor_name, :string, null: false
      add :file_url, :string
      add :filename, :string
      add :file_size_bytes, :bigint
      add :mime_type, :string

      # Client-side extracted text (pdfjs) — grounds the Groq analysis.
      add :content_text, :text

      # AI analysis, filled by POST /analyze. Stored as jsonb so we can add
      # fields later (ex. delivery_time, warranty) without migrations.
      add :analysis, :map
      add :analyzed_at, :utc_datetime
      add :analysis_model, :string

      timestamps(type: :utc_datetime)
    end

    create index(:project_devis, [:project_id])
  end
end
