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

    # Une doléance vit soit sur un bâtiment précis, soit sur la résidence
    # entière (visible à tous les bâtiments). Verrou DB via le
    # check_constraint `case_scope_xor` (cf. migration AddResidenceScopeToCases).
    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :residence, KomunBackend.Residences.Residence
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
      :residence_id,
      :author_id,
      :linked_incident_id
    ])
    |> validate_required([:title, :description, :category, :author_id])
    |> validate_length(:title, min: 5, max: 200)
    |> validate_length(:description, min: 10)
    |> validate_scope_xor()
    |> assoc_constraint(:linked_incident)
    |> check_constraint(:building_id, name: :case_scope_xor,
                        message: "doit être lié à un bâtiment OU à une résidence, pas aux deux")
  end

  # Voir doc dans `KomunBackend.Incidents.Incident.changeset/2`.
  defp validate_scope_xor(changeset) do
    building = get_field(changeset, :building_id)
    residence = get_field(changeset, :residence_id)

    cond do
      building && residence ->
        add_error(changeset, :residence_id,
          "ne peut pas être défini si building_id est aussi défini")

      is_nil(building) && is_nil(residence) ->
        add_error(changeset, :building_id,
          "building_id ou residence_id est requis")

      true ->
        changeset
    end
  end
end
