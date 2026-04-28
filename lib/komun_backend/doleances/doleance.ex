defmodule KomunBackend.Doleances.Doleance do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "doleances" do
    field :title, :string
    field :description, :string

    field :category, Ecto.Enum,
      values: [
        :structure,
        :parties_communes,
        :construction_defect,
        :voirie_parking,
        :nuisance,
        :security,
        :equipement,
        :autre
      ],
      default: :autre

    field :severity, Ecto.Enum,
      values: [:critical, :high, :medium, :low],
      default: :medium

    field :status, Ecto.Enum,
      values: [:brouillon, :open, :escalated, :resolved, :closed, :rejected],
      default: :open

    field :photo_urls, {:array, :string}, default: []
    field :document_urls, {:array, :string}, default: []

    field :target_kind, Ecto.Enum,
      values: [:syndic, :constructor, :insurance, :authority, :other]

    field :target_name, :string
    field :target_email, :string
    field :target_address, :string

    field :ai_letter, :string
    field :ai_letter_generated_at, :utc_datetime
    field :ai_expert_suggestions, :string
    field :ai_suggestions_generated_at, :utc_datetime
    field :ai_model, :string

    field :escalated_at, :utc_datetime
    field :resolved_at, :utc_datetime
    field :resolution_note, :string

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :author, KomunBackend.Accounts.User, foreign_key: :author_id

    # Doléance issue d'un incident (« dégât → garantie → doléance »).
    # Optionnel : la plupart des doléances naissent indépendamment d'un
    # signalement. ON DELETE NILIFY côté DB.
    belongs_to :linked_incident, KomunBackend.Incidents.Incident,
      foreign_key: :linked_incident_id

    has_many :supports, KomunBackend.Doleances.DoleanceSupport
    has_many :events, KomunBackend.Doleances.DoleanceEvent, preload_order: [asc: :inserted_at]
    has_many :files, KomunBackend.Doleances.DoleanceFile

    timestamps(type: :utc_datetime)
  end

  def changeset(doleance, attrs) do
    doleance
    |> cast(attrs, [
      :title,
      :description,
      :category,
      :severity,
      :status,
      :photo_urls,
      :document_urls,
      :target_kind,
      :target_name,
      :target_email,
      :target_address,
      :ai_letter,
      :ai_letter_generated_at,
      :ai_expert_suggestions,
      :ai_suggestions_generated_at,
      :ai_model,
      :escalated_at,
      :resolved_at,
      :resolution_note,
      :building_id,
      :author_id,
      :linked_incident_id
    ])
    |> validate_required([:title, :description, :category, :building_id, :author_id])
    |> validate_length(:title, min: 5, max: 200)
    |> validate_length(:description, min: 10)
    |> assoc_constraint(:linked_incident)
  end
end
