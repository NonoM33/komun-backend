defmodule KomunBackendWeb.VotesChannelTest do
  @moduledoc """
  Channel-level tests for `KomunBackendWeb.VotesChannel`.

  Covers:
  - Building member can join `votes:building:<id>`.
  - Non-member is rejected with `unauthorized`.
  - Super admin can join even without explicit membership.
  - `broadcast_vote_updated/2` pushes a `vote:updated` frame to joined sockets.
  - Broadcast payload contains no user-specific PII (no `user_id`, no
    `responses`, no `my_choice`).
  """

  use KomunBackendWeb.ChannelCase, async: false

  alias KomunBackend.{Buildings, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Residences.Residence
  alias KomunBackendWeb.{UserSocket, VotesChannel}

  defp insert_residence! do
    {:ok, r} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: "Résidence #{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> KomunBackend.Repo.insert()

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
    |> KomunBackend.Repo.insert!()
  end

  defp insert_user!(role \\ :coproprietaire) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> KomunBackend.Repo.insert!()
  end

  defp join_socket(user, topic) do
    UserSocket
    |> socket("user_socket:#{user.id}", %{current_user: user})
    |> subscribe_and_join(VotesChannel, topic)
  end

  describe "join/3" do
    test "member of the building can join" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, user.id)

      assert {:ok, _reply, socket} = join_socket(user, "votes:building:#{building.id}")
      assert socket.assigns.building_id == building.id
    end

    test "non-member is rejected with unauthorized" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()

      assert {:error, %{reason: "unauthorized"}} =
               join_socket(user, "votes:building:#{building.id}")
    end

    test "super_admin can join any building without membership" do
      residence = insert_residence!()
      building = insert_building!(residence)
      admin = insert_user!(:super_admin)

      assert {:ok, _reply, _socket} = join_socket(admin, "votes:building:#{building.id}")
    end
  end

  describe "broadcast_vote_updated/2" do
    setup do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, user.id)

      {:ok, _, socket} = join_socket(user, "votes:building:#{building.id}")
      %{building: building, socket: socket}
    end

    test "pushes vote:updated to joined sockets", %{building: building} do
      payload = %{
        vote_id: Ecto.UUID.generate(),
        tally: %{yes: 2, no: 1, abstain: 0, total: 3},
        option_counts: %{},
        status: :open,
        updated_at: DateTime.utc_now()
      }

      VotesChannel.broadcast_vote_updated(building.id, payload)
      assert_push("vote:updated", ^payload)
    end

    test "broadcast payload omits user-specific fields", %{building: building} do
      payload = %{
        vote_id: Ecto.UUID.generate(),
        tally: %{yes: 1, no: 0, abstain: 0, total: 1},
        option_counts: %{},
        status: :open,
        updated_at: DateTime.utc_now()
      }

      VotesChannel.broadcast_vote_updated(building.id, payload)
      assert_push("vote:updated", received)

      refute Map.has_key?(received, :user_id)
      refute Map.has_key?(received, :responses)
      refute Map.has_key?(received, :my_choice)
      refute Map.has_key?(received, :has_voted)
    end
  end
end
