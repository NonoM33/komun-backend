defmodule KomunBackend.Events.EventComment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "event_comments" do
    field :body, :string
    # Forme : %{"❤️" => %{"count" => 3, "user_ids" => [uuid, ...]}, "🍕" => …}.
    # Stocké en jsonb pour éviter une 8e table — réactions emoji = feature
    # cosmétique sans logique métier (pas de query, pas de stats).
    field :reactions, :map, default: %{}

    belongs_to :event, KomunBackend.Events.Event
    belongs_to :author, KomunBackend.Accounts.User, foreign_key: :author_id

    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:event_id, :author_id, :body, :reactions])
    |> validate_required([:event_id, :author_id, :body])
    |> validate_length(:body, min: 1, max: 5_000)
  end
end
