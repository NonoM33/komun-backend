defmodule KomunBackend.Events.EventBuildingScope do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  # Table pivot : un event scopé à certains bâtiments d'une résidence.
  # Aucune ligne pour un event = visible à toute la résidence (règle
  # « invisible totalement » côté visibility, on filtre en amont dans
  # `Events.list_events_for_building/3`).
  schema "event_building_scopes" do
    belongs_to :event, KomunBackend.Events.Event, primary_key: true
    belongs_to :building, KomunBackend.Buildings.Building, primary_key: true

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(scope, attrs) do
    scope
    |> cast(attrs, [:event_id, :building_id])
    |> validate_required([:event_id, :building_id])
    |> unique_constraint([:event_id, :building_id], name: :event_building_scopes_pkey)
  end
end
