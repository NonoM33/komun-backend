defmodule KomunBackendWeb.BuildingChannel do
  use KomunBackendWeb, :channel

  alias KomunBackend.Buildings

  @impl true
  def join("building:" <> building_id, _payload, socket) do
    user = socket.assigns.current_user

    if Buildings.member?(building_id, user.id) do
      {:ok, assign(socket, :building_id, building_id)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  # Broadcast incident updates to all building members
  def broadcast_incident(building_id, incident) do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "building:#{building_id}",
      {:incident_updated, incident}
    )
  end

  # Broadcast announcement to all building members
  def broadcast_announcement(building_id, announcement) do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "building:#{building_id}",
      {:announcement_published, announcement}
    )
  end

  # Broadcast doléance updates (create / edit / support added) to all members
  def broadcast_doleance(building_id, doleance) do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "building:#{building_id}",
      {:doleance_updated, doleance}
    )
  end

  # ── Events broadcasts ─────────────────────────────────────────────────────
  #
  # Le contexte `Events` boucle sur les bâtiments du scope et appelle ces
  # helpers — chaque membre étant dans le canal de SON bâtiment, c'est la
  # façon la plus simple de pousser un event sans canal résidence dédié.
  #
  # `action` ∈ :created | :updated | :cancelled — propagé au front pour
  # ajuster le toast (« Nouvel événement », « Événement annulé »…).
  def broadcast_event(building_id, event, action) when action in [:created, :updated, :cancelled] do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "building:#{building_id}",
      {:event_updated, event, action}
    )
  end

  def broadcast_event_participation(building_id, event_id, participation) do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "building:#{building_id}",
      {:event_participation_updated, event_id, participation}
    )
  end

  def broadcast_event_participation_removed(building_id, event_id, user_id) do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "building:#{building_id}",
      {:event_participation_removed, event_id, user_id}
    )
  end

  def broadcast_event_contributions(building_id, event_id, contributions) do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "building:#{building_id}",
      {:event_contributions_updated, event_id, contributions}
    )
  end

  def broadcast_event_comment(building_id, event_id, comment) do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "building:#{building_id}",
      {:event_comment_updated, event_id, comment}
    )
  end

  def broadcast_event_comment_removed(building_id, event_id, comment_id) do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "building:#{building_id}",
      {:event_comment_removed, event_id, comment_id}
    )
  end

  @impl true
  def handle_info({:incident_updated, incident}, socket) do
    push(socket, "incident:updated", %{incident: incident})
    {:noreply, socket}
  end

  def handle_info({:announcement_published, announcement}, socket) do
    push(socket, "announcement:new", %{announcement: announcement})
    {:noreply, socket}
  end

  def handle_info({:doleance_updated, doleance}, socket) do
    push(socket, "doleance:updated", %{doleance: doleance})
    {:noreply, socket}
  end

  def handle_info({:event_updated, event, action}, socket) do
    push(socket, "event:updated", %{event: serialize_event(event), action: to_string(action)})
    {:noreply, socket}
  end

  def handle_info({:event_participation_updated, event_id, participation}, socket) do
    push(socket, "event:participation:updated", %{
      event_id: event_id,
      participation: serialize_participation(participation)
    })

    {:noreply, socket}
  end

  def handle_info({:event_participation_removed, event_id, user_id}, socket) do
    push(socket, "event:participation:removed", %{event_id: event_id, user_id: user_id})
    {:noreply, socket}
  end

  def handle_info({:event_contributions_updated, event_id, contributions}, socket) do
    push(socket, "event:contributions:updated", %{
      event_id: event_id,
      contributions: Enum.map(contributions, &serialize_contribution/1)
    })

    {:noreply, socket}
  end

  def handle_info({:event_comment_updated, event_id, comment}, socket) do
    push(socket, "event:comment:updated", %{
      event_id: event_id,
      comment: serialize_comment(comment)
    })

    {:noreply, socket}
  end

  def handle_info({:event_comment_removed, event_id, comment_id}, socket) do
    push(socket, "event:comment:removed", %{event_id: event_id, comment_id: comment_id})
    {:noreply, socket}
  end

  # Sérialisations légères pour les pushes WebSocket — on évite d'envoyer
  # tous les preloads complets de l'event (ça doublerait la payload du
  # GET initial). Le front a déjà l'event, ces messages lui disent juste
  # quoi patcher dans son state local.

  defp serialize_event(event) do
    %{
      id: event.id,
      title: event.title,
      status: event.status,
      cancelled_at: event.cancelled_at,
      cancelled_reason: event.cancelled_reason,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      updated_at: event.updated_at
    }
  end

  defp serialize_participation(p) do
    %{
      id: p.id,
      event_id: p.event_id,
      user_id: p.user_id,
      status: p.status,
      plus_ones_count: p.plus_ones_count,
      dietary_note: p.dietary_note,
      user: maybe_user(p.user)
    }
  end

  defp serialize_contribution(c) do
    %{
      id: c.id,
      event_id: c.event_id,
      title: c.title,
      category: c.category,
      needed_quantity: c.needed_quantity,
      created_by_id: c.created_by_id,
      claims: Enum.map(claims_or_empty(c), &serialize_claim/1)
    }
  end

  defp claims_or_empty(%{claims: %Ecto.Association.NotLoaded{}}), do: []
  defp claims_or_empty(%{claims: claims}) when is_list(claims), do: claims
  defp claims_or_empty(_), do: []

  defp serialize_claim(claim) do
    %{
      id: claim.id,
      contribution_id: claim.contribution_id,
      user_id: claim.user_id,
      quantity: claim.quantity,
      comment: claim.comment,
      user: maybe_user(claim.user)
    }
  end

  defp serialize_comment(c) do
    %{
      id: c.id,
      event_id: c.event_id,
      author_id: c.author_id,
      body: c.body,
      reactions: c.reactions || %{},
      author: maybe_user(c.author),
      inserted_at: c.inserted_at
    }
  end

  defp maybe_user(%Ecto.Association.NotLoaded{}), do: nil
  defp maybe_user(nil), do: nil

  defp maybe_user(u) do
    %{
      id: u.id,
      first_name: u.first_name,
      last_name: u.last_name,
      avatar_url: Map.get(u, :avatar_url)
    }
  end
end
