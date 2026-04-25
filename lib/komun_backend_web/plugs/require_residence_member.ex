defmodule KomunBackendWeb.Plugs.RequireResidenceMember do
  @moduledoc """
  Vérifie que l'utilisateur authentifié est membre actif d'au moins un
  bâtiment de la résidence ciblée par `:residence_id`. Retourne 403 sinon.

  Utilisé par les routes "lecture" résidence-scope (ex : flux RSS,
  membres agrégés). Le `super_admin` passe systématiquement.
  """
  import Plug.Conn
  import Phoenix.Controller
  import Ecto.Query

  alias KomunBackend.Repo
  alias KomunBackend.Buildings.{Building, BuildingMember}

  def init(opts), do: opts

  def call(conn, _opts) do
    user = Guardian.Plug.current_resource(conn)
    residence_id = conn.params["residence_id"]

    cond do
      is_nil(user) ->
        forbid(conn)

      user.role == :super_admin ->
        conn

      is_nil(residence_id) ->
        forbid(conn)

      member?(user.id, residence_id) ->
        conn

      true ->
        forbid(conn)
    end
  end

  defp member?(user_id, residence_id) do
    Repo.exists?(
      from m in BuildingMember,
        join: b in Building,
        on: b.id == m.building_id,
        where:
          m.user_id == ^user_id and
            m.is_active == true and
            b.residence_id == ^residence_id
    )
  end

  defp forbid(conn) do
    conn
    |> put_status(403)
    |> json(%{error: "Forbidden"})
    |> halt()
  end
end
