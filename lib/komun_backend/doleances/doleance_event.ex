defmodule KomunBackend.Doleances.DoleanceEvent do
  @moduledoc """
  Timeline append-only d'une doléance.

  Chaque action significative produit une ligne :
  création, escalade, résolution, fermeture, rejet, lettre IA générée,
  suggestions d'experts générées, co-signature ajoutée ou retirée,
  email envoyé, relance.

  Le champ `payload` est un map JSON libre permettant de stocker le
  contexte utile à l'affichage (ex: `%{note: "..."}` pour resolved,
  `%{user_name: "Jean Dupont"}` pour support_added, etc.).

  Ce schéma est *append-only* — on ne fait jamais de UPDATE dessus.
  L'audit doit refléter ce qui s'est passé, pas une version révisable.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @event_types [
    :created,
    :escalated,
    :resolved,
    :closed,
    :rejected,
    :letter_generated,
    :experts_suggested,
    :support_added,
    :support_removed,
    :status_change
  ]

  schema "doleance_events" do
    field :event_type, Ecto.Enum, values: @event_types
    field :payload, :map, default: %{}

    belongs_to :doleance, KomunBackend.Doleances.Doleance
    belongs_to :actor, KomunBackend.Accounts.User, foreign_key: :actor_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def event_types, do: @event_types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :payload, :doleance_id, :actor_id])
    |> validate_required([:event_type, :doleance_id])
    |> validate_payload_size()
  end

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
