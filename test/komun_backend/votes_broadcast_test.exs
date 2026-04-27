defmodule KomunBackend.VotesBroadcastTest do
  @moduledoc """
  Asserts that the Votes context emits broadcasts on the right PubSub topic
  after a successful `respond/3`, `close_vote/1`, and `create_vote/3`.

  The frontend uses these broadcasts to invalidate its React-Query cache
  for the votes list — without them, other voters wouldn't see live tally
  updates without refreshing the page.

  Subscribes via `Phoenix.PubSub.subscribe(KomunBackend.PubSub, topic)`
  rather than going through the full channel join (covered separately
  in VotesChannelTest).
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Residences, Votes}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Residences.Residence

  defp insert_residence! do
    {:ok, r} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: "Résidence #{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> Repo.insert()

    r
  end

  defp insert_building!(residence) do
    %Building{}
    |> Building.initial_changeset(%{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "1 rue du Vote",
      city: "Paris",
      postal_code: "75001",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    })
    |> Repo.insert!()
  end

  defp insert_user!(role \\ :coproprietaire) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp setup_actors do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!()
    %{building: building, user: user}
  end

  defp subscribe!(building_id) do
    :ok = Phoenix.PubSub.subscribe(KomunBackend.PubSub, "votes:building:#{building_id}")
  end

  describe "respond/3 broadcast" do
    test "emits {:vote_updated, payload} after a successful binary vote" do
      %{building: b, user: u} = setup_actors()
      {:ok, vote} = Votes.create_vote(b.id, u.id, %{"title" => "Ravalement"})

      subscribe!(b.id)

      assert {:ok, _resp} = Votes.respond(vote.id, u.id, %{"choice" => "yes"})

      assert_receive {:vote_updated, payload}, 500
      assert payload.vote_id == vote.id
      assert payload.tally == %{yes: 1, no: 0, abstain: 0, total: 1}
      assert payload.status == :open
    end

    test "broadcast payload contains no user-specific fields" do
      %{building: b, user: u} = setup_actors()
      {:ok, vote} = Votes.create_vote(b.id, u.id, %{"title" => "Vote anonymisé"})

      subscribe!(b.id)

      {:ok, _} = Votes.respond(vote.id, u.id, %{"choice" => "yes"})

      assert_receive {:vote_updated, payload}, 500
      refute Map.has_key?(payload, :user_id)
      refute Map.has_key?(payload, :responses)
      refute Map.has_key?(payload, :my_choice)
      refute Map.has_key?(payload, :has_voted)
    end

    test "emits a fresh broadcast on re-vote with updated tally" do
      %{building: b, user: u} = setup_actors()
      {:ok, vote} = Votes.create_vote(b.id, u.id, %{"title" => "Re-vote test"})

      subscribe!(b.id)

      {:ok, _} = Votes.respond(vote.id, u.id, %{"choice" => "yes"})
      assert_receive {:vote_updated, %{tally: %{yes: 1, total: 1}}}, 500

      {:ok, _} = Votes.respond(vote.id, u.id, %{"choice" => "no"})
      assert_receive {:vote_updated, %{tally: %{yes: 0, no: 1, total: 1}}}, 500
    end
  end

  describe "close_vote/1 broadcast" do
    test "emits a vote_updated with status closed" do
      %{building: b, user: u} = setup_actors()
      {:ok, vote} = Votes.create_vote(b.id, u.id, %{"title" => "Vote à clore"})

      subscribe!(b.id)

      {:ok, _closed} = Votes.close_vote(vote)
      assert_receive {:vote_updated, %{vote_id: id, status: :closed}}, 500
      assert id == vote.id
    end
  end

  describe "create_vote/3 broadcast" do
    test "emits a vote_created with the new vote id and tally at zero" do
      %{building: b, user: u} = setup_actors()

      subscribe!(b.id)

      {:ok, vote} = Votes.create_vote(b.id, u.id, %{"title" => "Nouveau"})

      assert_receive {:vote_created, %{vote_id: id, tally: tally}}, 500
      assert id == vote.id
      assert tally.total == 0
    end
  end
end
