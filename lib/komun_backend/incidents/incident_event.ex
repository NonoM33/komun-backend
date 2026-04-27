defmodule KomunBackend.Incidents.IncidentEvent do
  @moduledoc """
  Timeline structurée d'un incident. Chaque mutation significative
  (création, changement de statut, relance, action syndic, commentaire,
  validation IA, lien vers une doléance) produit une ligne, ce qui
  permet d'afficher côté résident "qui a fait quoi quand" sans
  reconstruire l'historique à partir des champs Incident eux-mêmes.

  Note : ce schéma est *append-only* — on ne fait jamais de update.
  L'audit doit refléter ce qui s'est passé, pas une version révisable.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @event_types [
    :created,
    :status_change,
    :follow_up,
    :syndic_action,
    :comment_added,
    :photo_added,
    :ai_confirmed,
    :linked_doleance,
    :unlinked_doleance
  ]

  schema "incident_events" do
    field :event_type, Ecto.Enum, values: @event_types
    field :payload, :map, default: %{}

    belongs_to :incident, KomunBackend.Incidents.Incident
    belongs_to :actor, KomunBackend.Accounts.User, foreign_key: :actor_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def event_types, do: @event_types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :payload, :incident_id, :actor_id])
    |> validate_required([:event_type, :incident_id])
    |> validate_payload_size()
  end

  # Garde-fou simple : on ne veut pas qu'un payload non borné finisse en
  # base. 4 KB est largement au-dessus des cas d'usage actuels (status
  # diff, message de relance résumé, doleance_id) et aligne le coût
  # stockage sur l'audit_log existant.
  defp validate_payload_size(changeset) do
    case get_field(changeset, :payload) do
      nil ->
        changeset

      payload when is_map(payload) ->
        case Jason.encode(payload) do
          {:ok, json} when byte_size(json) <= 4096 ->
            changeset

          {:ok, _too_big} ->
            add_error(changeset, :payload, "is too large (max 4KB serialized)")

          {:error, _} ->
            add_error(changeset, :payload, "is not JSON-serializable")
        end

      _ ->
        add_error(changeset, :payload, "must be a map")
    end
  end
end
