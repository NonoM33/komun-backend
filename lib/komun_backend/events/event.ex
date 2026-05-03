defmodule KomunBackend.Events.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "events" do
    field :title, :string
    field :description, :string
    field :cover_image_url, :string

    field :kind, Ecto.Enum,
      values: [:festif, :reunion_conseil, :atelier, :ag, :autre],
      default: :festif

    field :status, Ecto.Enum,
      values: [:draft, :published, :cancelled, :completed],
      default: :draft

    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime

    field :location_label, :string
    field :location_details, :string

    field :max_participants, :integer
    field :requires_registration, :boolean, default: true
    field :allow_plus_ones, :boolean, default: true
    field :kid_friendly, :boolean, default: true

    field :cancelled_at, :utc_datetime
    field :cancelled_reason, :string

    belongs_to :residence, KomunBackend.Residences.Residence
    belongs_to :creator, KomunBackend.Accounts.User, foreign_key: :creator_id

    has_many :participations, KomunBackend.Events.EventParticipation
    has_many :building_scopes, KomunBackend.Events.EventBuildingScope
    has_many :organizers, KomunBackend.Events.EventOrganizer
    has_many :contributions, KomunBackend.Events.EventContribution
    has_many :comments, KomunBackend.Events.EventComment

    timestamps(type: :utc_datetime)
  end

  @castable [
    :title,
    :description,
    :cover_image_url,
    :kind,
    :status,
    :starts_at,
    :ends_at,
    :location_label,
    :location_details,
    :max_participants,
    :requires_registration,
    :allow_plus_ones,
    :kid_friendly,
    :residence_id,
    :creator_id
  ]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @castable)
    |> validate_required([:title, :starts_at, :ends_at, :residence_id, :creator_id])
    |> validate_length(:title, min: 3, max: 200)
    |> validate_length(:location_label, max: 200)
    |> validate_max_participants()
    |> validate_chronology()
  end

  # `:cancelled_at` / `:cancelled_reason` ne passent QUE par le
  # `cancel_changeset/2` ci-dessous. Évite qu'un PATCH générique annule
  # l'event en envoyant ces champs « par accident » dans son payload.
  def cancel_changeset(event, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    event
    |> cast(%{cancelled_at: now, cancelled_reason: reason, status: :cancelled},
            [:cancelled_at, :cancelled_reason, :status])
  end

  defp validate_max_participants(cs) do
    case get_field(cs, :max_participants) do
      nil -> cs
      n when is_integer(n) and n > 0 -> cs
      _ -> add_error(cs, :max_participants, "doit être un entier strictement positif")
    end
  end

  defp validate_chronology(cs) do
    starts = get_field(cs, :starts_at)
    ends = get_field(cs, :ends_at)

    cond do
      is_nil(starts) or is_nil(ends) ->
        cs

      DateTime.compare(ends, starts) in [:gt, :eq] ->
        cs

      true ->
        add_error(cs, :ends_at, "doit être postérieur ou égal à starts_at")
    end
  end
end
