defmodule KomunBackend.Votes do
  @moduledoc "Votes context — scoped by building."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Votes.{Vote, VoteResponse}

  def list_votes(building_id) do
    from(v in Vote,
      where: v.building_id == ^building_id,
      preload: [:created_by, :responses],
      order_by: [desc: v.inserted_at]
    )
    |> Repo.all()
  end

  def get_vote!(id) do
    Repo.get!(Vote, id)
    |> Repo.preload([:created_by, responses: :user])
  end

  def create_vote(building_id, user_id, attrs) do
    attrs = Map.merge(attrs, %{"building_id" => building_id, "created_by_id" => user_id})
    with {:ok, vote} <- %Vote{} |> Vote.changeset(attrs) |> Repo.insert() do
      {:ok, get_vote!(vote.id)}
    end
  end

  def close_vote(vote) do
    vote
    |> Ecto.Changeset.change(status: :closed)
    |> Repo.update()
  end

  def respond(vote_id, user_id, choice) do
    case Repo.get_by(VoteResponse, vote_id: vote_id, user_id: user_id) do
      nil ->
        %VoteResponse{}
        |> VoteResponse.changeset(%{vote_id: vote_id, user_id: user_id, choice: choice})
        |> Repo.insert()

      existing ->
        existing
        |> VoteResponse.changeset(%{choice: choice})
        |> Repo.update()
    end
  end

  def has_voted?(vote_id, user_id) do
    Repo.exists?(
      from(r in VoteResponse,
        where: r.vote_id == ^vote_id and r.user_id == ^user_id
      )
    )
  end

  def tally(vote) do
    responses = case vote.responses do
      %Ecto.Association.NotLoaded{} -> []
      r -> r
    end
    yes     = Enum.count(responses, &(&1.choice == :yes))
    no      = Enum.count(responses, &(&1.choice == :no))
    abstain = Enum.count(responses, &(&1.choice == :abstain))
    %{yes: yes, no: no, abstain: abstain, total: length(responses)}
  end
end
