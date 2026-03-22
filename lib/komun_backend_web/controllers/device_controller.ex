defmodule KomunBackendWeb.DeviceController do
  use KomunBackendWeb, :controller
  alias KomunBackend.{Accounts, Auth.Guardian}

  def register(conn, %{"token" => token}) do
    user = Guardian.Plug.current_resource(conn)
    {:ok, _} = Accounts.register_push_token(user, token)
    json(conn, %{message: "Device registered"})
  end

  def unregister(conn, %{"token" => token}) do
    user = Guardian.Plug.current_resource(conn)
    {:ok, _} = Accounts.unregister_push_token(user, token)
    send_resp(conn, :no_content, "")
  end
end
