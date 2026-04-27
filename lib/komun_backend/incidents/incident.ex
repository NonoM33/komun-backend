defmodule KomunBackend.Incidents.Incident do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "incidents" do
    field :title, :string
    field :description, :string
    # Résumé ultra-court (~ 1 phrase, ≤ 200 chars) généré par Groq via
    # `AI.IncidentSummarizer`. Affiché dans la vue liste/Kanban pour
    # donner le contexte du dossier en un coup d'œil sans gonfler les
    # cards. Tombe en fallback sur la 1re ligne de la description si la
    # regen échoue.
    field :micro_summary, :string
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

    # Niveau de confidentialité :
    # - :standard     → visible à tous les membres du bâtiment
    # - :council_only → réservé au syndic / conseil syndical / super_admin.
    #                   L'identité du signaleur n'est jamais divulguée dans
    #                   le payload sérialisé, l'IA n'est pas déclenchée
    #                   (contenu sensible) et les notifs push ne partent
    #                   qu'aux rôles privilégiés.
    field :visibility, Ecto.Enum, values: [:standard, :council_only], default: :standard

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
    |> cast(attrs, [:title, :description, :micro_summary, :category, :severity, :status,
                    :photo_urls, :location, :lot_number, :building_id, :reporter_id,
                    :assignee_id, :resolution_note, :visibility,
                    :ai_answer, :ai_answered_at, :ai_model,
                    :ai_answer_confirmed_at, :ai_answer_confirmed_by_id])
    |> validate_required([:title, :description, :category, :building_id, :reporter_id])
    |> validate_length(:title, min: 5, max: 200)
    |> validate_length(:micro_summary, max: 200)
  end

  def resolve_changeset(incident, note) do
    incident
    |> cast(%{status: :resolved, resolution_note: note,
              resolved_at: DateTime.utc_now() |> DateTime.truncate(:second)}, [:status, :resolution_note, :resolved_at])
  end
end
