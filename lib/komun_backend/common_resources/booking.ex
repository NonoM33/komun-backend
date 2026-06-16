defmodule KomunBackend.CommonResources.Booking do
  @moduledoc """
  Demande de réservation d'une `CommonResource` par un résident. Le
  workflow est : `pending` → `approved` ou `rejected` (par n'importe
  quel membre du conseil syndical), avec possibilité d'annulation par
  le demandeur tant que la date de début n'est pas passée.

  Le respect du préavis (`advance_notice_hours`) et de la fenêtre
  horaire autorisée (`allowed_hours_*`) est validé à la création — on
  ne peut donc pas créer une demande pour demain matin si la ressource
  exige 48h. Les chevauchements sur ressource exclusive sont vérifiés
  dans le contexte (pas via une exclusion DB pour rester simple en V1
  — à durcir avec un EXCLUDE Postgres si on voit des collisions).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :approved, :rejected, :cancelled]

  schema "common_resource_bookings" do
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :reason, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :validated_at, :utc_datetime
    field :rejection_reason, :string

    belongs_to :common_resource, KomunBackend.CommonResources.Resource
    belongs_to :requester, KomunBackend.Accounts.User, foreign_key: :requester_id
    belongs_to :validated_by, KomunBackend.Accounts.User, foreign_key: :validated_by_id

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc """
  Changeset à la création — l'utilisateur fournit `starts_at`,
  `ends_at`, `reason`. `requester_id`, `common_resource_id` et `status`
  (toujours `:pending`) sont injectés par le contexte.
  """
  def create_changeset(booking, attrs) do
    booking
    |> cast(attrs, [:starts_at, :ends_at, :reason, :common_resource_id, :requester_id])
    |> validate_required([:starts_at, :ends_at, :common_resource_id, :requester_id])
    |> validate_length(:reason, max: 500)
    |> validate_dates_order()
    |> put_change(:status, :pending)
    |> assoc_constraint(:common_resource)
    |> assoc_constraint(:requester)
  end

  @doc """
  Changeset utilisé par le contexte pour figer un statut de validation
  (`:approved`, `:rejected`) avec horodatage et auteur. Pas exposé tel
  quel aux controllers — passer par `CommonResources.approve_booking/2`
  ou `reject_booking/3`.
  """
  def validation_changeset(booking, attrs) do
    booking
    |> cast(attrs, [:status, :validated_by_id, :validated_at, :rejection_reason])
    |> validate_required([:status, :validated_by_id, :validated_at])
    |> validate_inclusion(:status, [:approved, :rejected])
    |> validate_length(:rejection_reason, max: 500)
    |> assoc_constraint(:validated_by)
  end

  @doc """
  Annulation par le demandeur (ou un admin). On garde la ligne pour
  l'historique — pas de hard delete.
  """
  def cancellation_changeset(booking) do
    change(booking, %{status: :cancelled})
  end

  defp validate_dates_order(changeset) do
    s = get_field(changeset, :starts_at)
    e = get_field(changeset, :ends_at)

    cond do
      is_nil(s) or is_nil(e) ->
        changeset

      DateTime.compare(e, s) != :gt ->
        add_error(changeset, :ends_at, "doit être strictement après starts_at")

      true ->
        changeset
    end
  end
end
