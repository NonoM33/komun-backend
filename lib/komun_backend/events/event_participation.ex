defmodule KomunBackend.Events.EventParticipation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_plus_ones 5

  schema "event_participations" do
    field :status, Ecto.Enum, values: [:going, :maybe, :declined], default: :going
    field :plus_ones_count, :integer, default: 0
    field :dietary_note, :string

    belongs_to :event, KomunBackend.Events.Event
    belongs_to :user, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(participation, attrs) do
    participation
    |> cast(attrs, [:event_id, :user_id, :status, :plus_ones_count, :dietary_note])
    |> validate_required([:event_id, :user_id])
    |> validate_number(:plus_ones_count, greater_than_or_equal_to: 0, less_than_or_equal_to: @max_plus_ones)
    |> validate_length(:dietary_note, max: 280)
    |> unique_constraint([:event_id, :user_id])
  end

  def max_plus_ones, do: @max_plus_ones
end
