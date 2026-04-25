defmodule KomunBackend.Votes.VoteResponse do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vote_responses" do
    # Binary vote payload (yes/no/abstain). Null for single_choice responses.
    field :choice, Ecto.Enum, values: [:yes, :no, :abstain]

    belongs_to :vote, KomunBackend.Votes.Vote
    belongs_to :user, KomunBackend.Accounts.User
    # Set when the parent vote is single_choice — references the chosen option.
    belongs_to :option, KomunBackend.Votes.VoteOption

    timestamps(type: :utc_datetime)
  end

  def changeset(response, attrs) do
    response
    |> cast(attrs, [:choice, :vote_id, :user_id, :option_id])
    |> validate_required([:vote_id, :user_id])
    |> validate_choice_or_option()
    |> unique_constraint([:vote_id, :user_id],
      name: :vote_responses_vote_id_user_id_index
    )
  end

  # Either :choice (binary) or :option_id (single_choice) must be set.
  defp validate_choice_or_option(changeset) do
    choice = get_field(changeset, :choice)
    option_id = get_field(changeset, :option_id)

    cond do
      choice && option_id ->
        add_error(changeset, :choice, "cannot set both choice and option_id")

      !choice && !option_id ->
        add_error(changeset, :choice, "must set either choice or option_id")

      true ->
        changeset
    end
  end
end
