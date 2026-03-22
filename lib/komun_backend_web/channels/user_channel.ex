defmodule KomunBackendWeb.UserChannel do
  use KomunBackendWeb, :channel

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    if socket.assigns.current_user.id == user_id do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  # Push a notification to a specific user
  def push_notification(user_id, type, payload) do
    Phoenix.PubSub.broadcast(
      KomunBackend.PubSub,
      "user:#{user_id}",
      {:notification, type, payload}
    )
  end

  @impl true
  def handle_info({:notification, type, payload}, socket) do
    push(socket, "notification", %{type: type, payload: payload})
    {:noreply, socket}
  end
end
