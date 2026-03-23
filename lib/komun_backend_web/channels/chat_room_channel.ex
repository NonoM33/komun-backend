defmodule KomunBackendWeb.ChatRoomChannel do
  use KomunBackendWeb, :channel

  alias KomunBackend.{Buildings, Chat, Repo}

  @impl true
  def join("room:" <> building_id, _payload, socket) do
    user = socket.assigns.current_user

    if user.role == :super_admin or Buildings.member?(building_id, user.id) do
      messages = Chat.list_messages("building:#{building_id}")
      socket = assign(socket, :building_id, building_id)
      {:ok, %{messages: format_messages(messages)}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("new_message", %{"body" => body}, socket)
      when is_binary(body) and byte_size(body) > 0 do
    user = socket.assigns.current_user
    building_id = socket.assigns.building_id
    room_id = "building:#{building_id}"

    case Chat.create_message(room_id, user.id, String.slice(body, 0, 4000)) do
      {:ok, message} ->
        message = Repo.preload(message, :author)
        payload = format_message(message)
        broadcast!(socket, "new_message", payload)
        {:reply, {:ok, payload}, socket}

      {:error, _changeset} ->
        {:reply, {:error, %{reason: "invalid"}}, socket}
    end
  end

  def handle_in("new_message", _payload, socket) do
    {:reply, {:error, %{reason: "empty_message"}}, socket}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp format_messages(messages), do: Enum.map(messages, &format_message/1)

  defp format_message(message) do
    %{
      id: message.id,
      body: message.body,
      author_id: to_string(message.author_id),
      author_name: author_name(message.author),
      author_avatar_url: message.author && message.author.avatar_url,
      inserted_at: DateTime.to_iso8601(message.inserted_at)
    }
  end

  defp author_name(nil), do: "Inconnu"

  defp author_name(user) do
    case {user.first_name, user.last_name} do
      {nil, nil} -> user.email
      {first, nil} -> first
      {nil, last} -> last
      {first, last} -> "#{first} #{last}"
    end
  end
end
