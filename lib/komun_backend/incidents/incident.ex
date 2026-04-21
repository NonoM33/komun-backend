defmodule KomunBackend.Incidents.Incident do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "incidents" do
    field :title, :string
    field :description, :string
    field :category, Ecto.Enum,
      values: [:plomberie, :electricite, :ascenseur, :serrurerie, :toiture,
               :facades, :parties_communes, :espaces_verts, :autre]
    field :severity, Ecto.Enum, values: [:critical, :high, :medium, :low], default: :medium
    field :status, Ecto.Enum,
      values: [:open, :in_progress, :resolved, :closed, :rejected], default: :open
    field :photo_urls, {:array, :string}, default: []
    field :resolved_at, :utc_datetime
    field :resolution_note, :string
    field :location, :string
    field :lot_number, :string

    # AI triage — populated asynchronously after creation. Residents see it
    # as "réponse proposée par l'assistant" until the syndic / conseil
    # confirms it (ai_answer_confirmed_at set).
    field :ai_answer, :string
    field :ai_answered_at, :utc_datetime
    field :ai_model, :string
    field :ai_answer_confirmed_at, :utc_datetime

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :reporter, KomunBackend.Accounts.User, foreign_key: :reporter_id
    belongs_to :assignee, KomunBackend.Accounts.User, foreign_key: :assignee_id
    belongs_to :ai_answer_confirmed_by, KomunBackend.Accounts.User,
      foreign_key: :ai_answer_confirmed_by_id
    has_many :comments, KomunBackend.Incidents.IncidentComment

    timestamps(type: :utc_datetime)
  end

  def changeset(incident, attrs) do
    incident
    |> cast(attrs, [:title, :description, :category, :severity, :status,
                    :photo_urls, :location, :lot_number, :building_id, :reporter_id,
                    :assignee_id, :resolution_note,
                    :ai_answer, :ai_answered_at, :ai_model,
                    :ai_answer_confirmed_at, :ai_answer_confirmed_by_id])
    |> validate_required([:title, :description, :category, :building_id, :reporter_id])
    |> validate_length(:title, min: 5, max: 200)
  end

  def resolve_changeset(incident, note) do
    incident
    |> cast(%{status: :resolved, resolution_note: note,
              resolved_at: DateTime.utc_now() |> DateTime.truncate(:second)}, [:status, :resolution_note, :resolved_at])
  end
end
