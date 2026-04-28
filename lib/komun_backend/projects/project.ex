defmodule KomunBackend.Projects.Project do
  @moduledoc """
  Copro project — groups devis (quotes) around a concrete need (ravalement,
  toiture, ascenseur…) so the conseil can collect, compare and put the chosen
  one to a vote.

  Un projet peut éventuellement être rattaché à **un seul dossier source**
  (incident / doléance / diligence). Les 3 FK sont nullable, mais on
  refuse explicitement plusieurs liens simultanés via le changeset :
  un projet « Devis ravalement » ne peut pas être à la fois lié à un
  incident et à une doléance, sinon le « Devis demandés » côté fiche
  dossier devient illisible.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:collecting, :voting, :chosen, :done]

  @link_fields [:linked_incident_id, :linked_doleance_id, :linked_diligence_id]

  schema "projects" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :collecting
    field :chosen_devis_id, :binary_id

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :created_by, KomunBackend.Accounts.User
    belongs_to :vote, KomunBackend.Votes.Vote
    has_many :devis, KomunBackend.Projects.Devis, preload_order: [asc: :inserted_at]

    # Liaison optionnelle vers le dossier qui a déclenché la demande de
    # devis. Au plus UN des trois est posé à la fois (cf. validation
    # `validate_single_link/1` plus bas).
    belongs_to :linked_incident, KomunBackend.Incidents.Incident,
      foreign_key: :linked_incident_id

    belongs_to :linked_doleance, KomunBackend.Doleances.Doleance,
      foreign_key: :linked_doleance_id

    belongs_to :linked_diligence, KomunBackend.Diligences.Diligence,
      foreign_key: :linked_diligence_id

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def link_fields, do: @link_fields

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :chosen_devis_id,
      :vote_id,
      :building_id,
      :created_by_id,
      :linked_incident_id,
      :linked_doleance_id,
      :linked_diligence_id
    ])
    |> validate_required([:title, :building_id])
    |> validate_length(:title, min: 3, max: 200)
    |> validate_single_link()
    |> assoc_constraint(:linked_incident)
    |> assoc_constraint(:linked_doleance)
    |> assoc_constraint(:linked_diligence)
  end

  # Refuse qu'un projet soit rattaché à plus d'un dossier à la fois.
  # On accepte 0 (projet libre) ou 1 (rattaché). 2+ → erreur explicite
  # plutôt qu'un comportement silencieux genre "on garde le premier".
  defp validate_single_link(changeset) do
    set_count =
      @link_fields
      |> Enum.count(fn f ->
        case get_field(changeset, f) do
          nil -> false
          _ -> true
        end
      end)

    if set_count > 1 do
      add_error(
        changeset,
        :linked_incident_id,
        "un projet ne peut être rattaché qu'à un seul dossier (incident, doléance ou diligence)"
      )
    else
      changeset
    end
  end
end
