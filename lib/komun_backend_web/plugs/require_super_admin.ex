defmodule KomunBackendWeb.Plugs.RequireSuperAdmin do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    user = Guardian.Plug.current_resource(conn)
    if user && user.role == :super_admin do
      conn
    else
      conn
      |> put_status(403)
      |> json(%{error: "Forbidden"})
      |> halt()
    end
  end
end
