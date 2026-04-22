defmodule KomunBackend.Projects.Devis do
  @moduledoc """
  A devis attached to a copro project. Members upload the PDF, the frontend
  extracts the text client-side (pdfjs) and stores it here; the AI analysis
  (price, pros, cons, summary) is produced on-demand via Groq.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "project_devis" do
    field :vendor_name, :string
    field :file_url, :string
    field :filename, :string
    field :file_size_bytes, :integer
    field :mime_type, :string
    field :content_text, :string
    field :analysis, :map
    field :analyzed_at, :utc_datetime
    field :analysis_model, :string

    belongs_to :project, KomunBackend.Projects.Project
    belongs_to :uploaded_by, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(devis, attrs) do
    devis
    |> cast(attrs, [
      :vendor_name,
      :file_url,
      :filename,
      :file_size_bytes,
      :mime_type,
      :content_text,
      :analysis,
      :analyzed_at,
      :analysis_model,
      :project_id,
      :uploaded_by_id
    ])
    |> validate_required([:vendor_name, :project_id])
    |> validate_length(:vendor_name, min: 1, max: 200)
  end
end
