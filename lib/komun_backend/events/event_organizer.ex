defmodule KomunBackend.Events.EventOrganizer do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  # Table pivot pour les co-organisateurs. Le créateur est lui-même
  # inscrit (rôle :creator) à la création de l'event, ce qui permet de
  # check « peut éditer / blast / annuler » via une seule requête sur
  # cette table — sans passer par event.creator_id en plus.
  schema "event_organizers" do
    belongs_to :event, KomunBackend.Events.Event, primary_key: true
    belongs_to :user, KomunBackend.Accounts.User, primary_key: true

    field :role, Ecto.Enum, values: [:creator, :co_organizer], default: :co_organizer

    timestamps(type: :utc_datetime)
  end

  def changeset(organizer, attrs) do
    organizer
    |> cast(attrs, [:event_id, :user_id, :role])
    |> validate_required([:event_id, :user_id])
    |> unique_constraint([:event_id, :user_id], name: :event_organizers_pkey)
  end
end
