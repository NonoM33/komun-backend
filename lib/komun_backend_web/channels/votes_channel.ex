defmodule KomunBackendWeb.VotesChannel do
  @moduledoc """
  Phoenix Channel that pushes live vote updates to all members of a building.

  Topic format: `votes:building:<building_id>`.

  Authorization on `join/3` requires either an active building membership
  (`Buildings.member?/2`) or the `super_admin` role. Non-members are
  rejected with `%{reason: "unauthorized"}`.

  Broadcast payloads are deliberately building-scoped — they never carry
  user-specific fields (`user_id`, `responses`, `my_choice`, `has_voted`).
  Per-user state stays in the REST `GET /votes` response, which the
  frontend re-fetches on each `vote:updated` push via React Query
  invalidation.

  Sister to `KomunBackendWeb.BuildingChannel` (which carries chat-adjacent
  events on `building:<id>`); kept on a separate topic so chat consumers
  don't pay for vote broadcast traffic and so we can later add per-vote
  topics like `votes:vote:<id>` without migrating subscribers.
  """

  use KomunBackendWeb, :channel

  alias KomunBackend.Buildings

  @impl true
  def join("votes:building:" <> building_id, _payload, socket) do
    user = socket.assigns.current_user

    if user.role == :super_admin or Buildings.member?(building_id, user.id) do
      {:ok, assign(socket, :building_id, building_id)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @doc """
  Broadcasts that a vote's tally changed (cast, re-cast, status flip).

  Called from `KomunBackend.Votes` after a successful response upsert and
  on `close_vote/1`. The payload must NOT include user-specific data —
  this is a building-wide broadcast.
  """
  def broadcast_vote_updated(building_id, payload) do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "votes:building:#{building_id}",
      {:vote_updated, payload}
    )
  end

  @doc """
  Broadcasts that a brand-new vote was created — frontends listening on
  this building topic prepend the card without polling.
  """
  def broadcast_vote_created(building_id, payload) do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "votes:building:#{building_id}",
      {:vote_created, payload}
    )
  end

  @impl true
  def handle_info({:vote_updated, payload}, socket) do
    push(socket, "vote:updated", payload)
    {:noreply, socket}
  end

  def handle_info({:vote_created, payload}, socket) do
    push(socket, "vote:created", payload)
    {:noreply, socket}
  end
end
