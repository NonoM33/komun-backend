defmodule KomunBackendWeb.UserSocket do
  use Phoenix.Socket

  # Channels
  channel "building:*", KomunBackendWeb.BuildingChannel
  channel "user:*", KomunBackendWeb.UserChannel
  channel "room:*", KomunBackendWeb.ChatRoomChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case KomunBackend.Auth.Guardian.decode_and_verify(token) do
      {:ok, claims} ->
        {:ok, user} = KomunBackend.Auth.Guardian.resource_from_claims(claims)
        {:ok, assign(socket, :current_user, user)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
