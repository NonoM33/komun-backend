defmodule KomunBackend.Votes.Vote do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "votes" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:open, :closed], default: :open
    field :ends_at, :utc_datetime
    field :is_anonymous, :boolean, default: false

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :created_by, KomunBackend.Accounts.User
    has_many :responses, KomunBackend.Votes.VoteResponse

    timestamps(type: :utc_datetime)
  end

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:title, :description, :status, :ends_at, :is_anonymous,
                    :building_id, :created_by_id])
    |> validate_required([:title, :building_id, :created_by_id])
    |> validate_length(:title, min: 3, max: 200)
  end
end
