defmodule KomunBackendWeb.AssemblyController do
  use KomunBackendWeb, :controller

  def index(conn, _params), do: json(conn, %{data: []})
  def show(conn, _params), do: json(conn, %{data: %{}})
  def create(conn, _params), do: conn |> put_status(:created) |> json(%{data: %{}})
  def update(conn, _params), do: json(conn, %{data: %{}})
  def delete(conn, _params), do: send_resp(conn, :no_content, "")
end
