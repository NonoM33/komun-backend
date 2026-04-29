defmodule KomunBackend.Diligences.Diligence do
  @moduledoc """
  Dossier de suivi d'un trouble anormal du voisinage (cannabis,
  nuisances sonores persistantes, comportements illicites…). Réservé
  au syndic et au conseil syndical : la création, la lecture et la
  mise à jour passent toutes par `authorize_privileged/3` côté
  controller. Voir `KomunBackend.Diligences` pour le contexte public
  et `KomunBackend.Diligences.Steps` pour la définition des 9 étapes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:brouillon, :open, :closed, :escalated]
  @source_types [:copro_owner, :tenant, :unknown]

  schema "diligences" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :source_type, Ecto.Enum, values: @source_types
    field :source_label, :string
    field :saisine_syndic_letter, :string
    field :mise_en_demeure_letter, :string

    # Une diligence vit soit sur un bâtiment précis, soit sur la résidence
    # entière. Verrou DB via le check_constraint `case_scope_xor` (cf.
    # migration AddResidenceScopeToCases).
    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :residence, KomunBackend.Residences.Residence
    belongs_to :created_by, KomunBackend.Accounts.User, foreign_key: :created_by_id

    belongs_to :linked_incident, KomunBackend.Incidents.Incident,
      foreign_key: :linked_incident_id

    has_many :steps, KomunBackend.Diligences.DiligenceStep,
      preload_order: [asc: :step_number]

    has_many :files, KomunBackend.Diligences.DiligenceFile,
      preload_order: [desc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def source_types, do: @source_types

  @doc """
  Changeset utilisé à la création (POST /diligences). On verrouille
  `building_id` et `created_by_id` parce que ces deux champs sont
  toujours dérivés du contexte d'appel — jamais du payload utilisateur.
  """
  def create_changeset(diligence, attrs) do
    diligence
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :source_type,
      :source_label,
      :building_id,
      :residence_id,
      :created_by_id,
      :linked_incident_id
    ])
    |> validate_required([:title, :created_by_id])
    |> validate_length(:title, min: 5, max: 200)
    |> validate_length(:source_label, max: 200)
    |> validate_scope_xor()
    |> assoc_constraint(:building)
    |> assoc_constraint(:residence)
    |> assoc_constraint(:created_by)
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

  @doc """
  Changeset d'édition. On strippe explicitement `building_id`,
  `created_by_id` et les courriers générés — ces derniers ont leur
  propre chemin (`Diligences.set_letter/3`) pour qu'on puisse versionner
  ou logger la génération sans confondre avec une édition manuelle.
  """
  def update_changeset(diligence, attrs) do
    diligence
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :source_type,
      :source_label,
      :linked_incident_id
    ])
    |> validate_length(:title, min: 5, max: 200)
    |> validate_length(:source_label, max: 200)
    |> assoc_constraint(:linked_incident)
  end

  @doc """
  Réservé au contexte (`Diligences.set_letter/3`) — le controller ne doit
  pas l'appeler directement, sinon n'importe qui ayant `update_changeset`
  pourrait écraser un courrier généré par l'IA.
  """
  def letter_changeset(diligence, kind, text) when kind in [:saisine, :mise_en_demeure] do
    field =
      case kind do
        :saisine -> :saisine_syndic_letter
        :mise_en_demeure -> :mise_en_demeure_letter
      end

    cast(diligence, %{field => text}, [field])
  end
end
