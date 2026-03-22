defmodule KomunBackendWeb.OrganizationController do
  use KomunBackendWeb, :controller

  def show(conn, %{"id" => _id}) do
    json(conn, %{data: %{message: "TODO"}})
  end

  def buildings(conn, %{"id" => _id}) do
    json(conn, %{data: []})
  end
end
