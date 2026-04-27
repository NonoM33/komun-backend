defmodule KomunBackendWeb.Plugs.RequireResidenceAdmin do
  @moduledoc """
  Autorise l'utilisateur si :
  - il est `super_admin` (rôle global), OU
  - il est membre actif d'un bâtiment de la résidence ciblée avec un
    rôle CS (`:president_cs` ou `:membre_cs`).

  Utilisé pour les routes "écriture" sur les ressources résidence-scope
  qui doivent rester sous contrôle admin (ex : configuration des flux
  RSS de l'actu locale).
  """
  import Plug.Conn
  import Phoenix.Controller
  import Ecto.Query

  alias KomunBackend.Repo
  alias KomunBackend.Buildings.{Building, BuildingMember}

  @cs_roles [:president_cs, :membre_cs]

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

      cs_member?(user.id, residence_id) ->
        conn

      true ->
        forbid(conn)
    end
  end

  defp cs_member?(user_id, residence_id) do
    Repo.exists?(
      from m in BuildingMember,
        join: b in Building,
        on: b.id == m.building_id,
        where:
          m.user_id == ^user_id and
            m.is_active == true and
            m.role in ^@cs_roles and
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
