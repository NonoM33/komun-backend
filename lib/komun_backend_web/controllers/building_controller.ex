defmodule KomunBackendWeb.BuildingController do
  use KomunBackendWeb, :controller

  alias KomunBackend.Buildings

  def index(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    # Super admin sees all active buildings
    results =
      if user.role == :super_admin do
        Buildings.list_all_buildings()
        |> Enum.filter(& &1.is_active)
        |> Enum.map(fn b -> {b, :syndic_manager} end)
      else
        Buildings.list_user_buildings(user.id)
      end

    json(conn, %{data: Enum.map(results, fn {b, role} ->
      %{
        id: b.id,
        name: b.name,
        address: b.address,
        city: b.city,
        postal_code: b.postal_code,
        lot_count: b.lot_count,
        cover_url: b.cover_url,
        role: role
      }
    end)})
  end

  def show(conn, %{"id" => id}) do
    building = Buildings.get_building!(id)
    json(conn, %{data: %{
      id: building.id,
      name: building.name,
      address: building.address,
      city: building.city,
      postal_code: building.postal_code,
      lot_count: building.lot_count,
      cover_url: building.cover_url
    }})
  end

  def members(conn, %{"id" => id}) do
    members = Buildings.list_members(id)
    json(conn, %{data: Enum.map(members, fn m ->
      %{
        id: m.id,
        role: m.role,
        joined_at: m.joined_at,
        user: %{
          id: m.user.id,
          email: m.user.email,
          first_name: m.user.first_name,
          last_name: m.user.last_name,
          avatar_url: m.user.avatar_url
        }
      }
    end)})
  end

  def lots(conn, %{"id" => id}) do
    lots = Buildings.list_lots(id)
    json(conn, %{data: Enum.map(lots, fn l ->
      %{id: l.id, number: l.number, type: l.type, floor: l.floor,
        area_sqm: l.area_sqm, tantieme: l.tantieme, is_occupied: l.is_occupied}
    end)})
  end
end
