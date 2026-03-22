defmodule KomunBackendWeb.VoteController do
  use KomunBackendWeb, :controller

  def index(conn, _params), do: json(conn, %{data: []})
  def respond(conn, _params), do: json(conn, %{data: %{}})
end
