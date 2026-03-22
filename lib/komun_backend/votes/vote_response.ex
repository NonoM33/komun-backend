defmodule KomunBackend.Votes.VoteResponse do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vote_responses" do
    field :choice, Ecto.Enum, values: [:yes, :no, :abstain]

    belongs_to :vote, KomunBackend.Votes.Vote
    belongs_to :user, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(response, attrs) do
    response
    |> cast(attrs, [:choice, :vote_id, :user_id])
    |> validate_required([:choice, :vote_id, :user_id])
    |> unique_constraint([:vote_id, :user_id],
        name: :vote_responses_vote_id_user_id_index)
  end
end
