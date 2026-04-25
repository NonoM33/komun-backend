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
end
