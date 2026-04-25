defmodule KomunBackend.Diligences.DiligenceStep do
  @moduledoc """
  Étape d'une diligence. Les 9 étapes sont créées d'office à
  l'instanciation de la diligence (cf. `Diligences.create_diligence/3`)
  avec `status: :pending`. Le client passe ensuite l'étape à
  `:in_progress` puis `:completed` au fil de la procédure.

  `:skipped` est réservé aux étapes optionnelles (étape 7 : plainte
  police) que le CS choisit de ne pas activer — utile pour que la
  barre de progression reflète la réalité plutôt que de rester bloquée
  à 88 %.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias KomunBackend.Diligences.Steps

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :in_progress, :completed, :skipped]

  schema "diligence_steps" do
    field :step_number, :integer
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :notes, :string
    field :completed_at, :utc_datetime

    belongs_to :diligence, KomunBackend.Diligences.Diligence

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc """
  Changeset utilisé uniquement à la création initiale (les 9 lignes
  posées en transaction avec la diligence). Le client n'a pas à passer
  par ce chemin — la création des étapes est entièrement pilotée par
  le contexte.
  """
  def create_changeset(step, attrs) do
    step
    |> cast(attrs, [:diligence_id, :step_number, :status, :notes, :completed_at])
    |> validate_required([:diligence_id, :step_number])
    |> validate_step_number()
    |> assoc_constraint(:diligence)
    |> unique_constraint([:diligence_id, :step_number])
  end

  @doc """
  Changeset d'update via PATCH /diligences/:id/steps/:n. Ne touche pas
  `step_number` ni `diligence_id` : un step ne peut pas changer
  d'étape ni de diligence. Les notes et le statut sont les seuls
  champs éditables côté API.

  `completed_at` est calculé automatiquement : on le set quand on
  passe à `:completed` et on le clear si on revient en arrière.
  """
  def update_changeset(step, attrs) do
    step
    |> cast(attrs, [:status, :notes])
    |> sync_completed_at()
  end

  defp sync_completed_at(changeset) do
    case get_change(changeset, :status) do
      :completed ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        put_change(changeset, :completed_at, now)

      status when status in [:pending, :in_progress, :skipped] ->
        put_change(changeset, :completed_at, nil)

      nil ->
        changeset
    end
  end

  defp validate_step_number(changeset) do
    case get_field(changeset, :step_number) do
      n when is_integer(n) ->
        if Steps.valid_number?(n) do
          changeset
        else
          add_error(changeset, :step_number, "must be between 1 and #{Steps.count()}")
        end

      _ ->
        changeset
    end
  end
end
