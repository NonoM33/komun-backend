defmodule KomunBackendWeb.HealthController do
  use KomunBackendWeb, :controller

  def check(conn, _) do
    json(conn, %{status: "ok", version: "0.1.0"})
  end
end
