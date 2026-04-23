defmodule KomunBackendWeb.BuildingController do
  use KomunBackendWeb, :controller

  alias KomunBackend.Buildings

  # Roles that should see the join code alongside their building — they are
  # the ones expected to hand it out to new residents.
  @privileged_roles [:president_cs, :syndic_manager, :syndic_staff]

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
      base = %{
        id: b.id,
        name: b.name,
        address: b.address,
        city: b.city,
        postal_code: b.postal_code,
        lot_count: b.lot_count,
        cover_url: b.cover_url,
        role: role
      }

      if user.role == :super_admin or role in @privileged_roles do
        Map.put(base, :join_code, b.join_code)
      else
        base
      end
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

  # GET /api/v1/buildings/verify_code?code=XXXXXXXX
  # Public endpoint — no auth. Lets a prospective resident confirm the code
  # matches a real building before creating an account via magic-link.
  def verify_code(conn, %{"code" => code}) when is_binary(code) and code != "" do
    case Buildings.get_building_by_join_code(code) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{valid: false, error: "invalid_code"})

      building ->
        json(conn, %{
          valid: true,
          building: %{
            id: building.id,
            name: building.name,
            address: building.address,
            city: building.city,
            postal_code: building.postal_code
          }
        })
    end
  end

  def verify_code(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{valid: false, error: "missing_code"})
  end

  # POST /api/v1/buildings/join
  # Body: %{"code" => "A1B2C3D4"}
  #
  # Any authenticated user can redeem a short code. New members join with the
  # `coproprietaire` role by default — syndics / CS presidents still onboard
  # through the dedicated invite-token flow.
  def join(conn, %{"code" => code}) when is_binary(code) do
    user = Guardian.Plug.current_resource(conn)

    case Buildings.join_by_code(code, user.id) do
      {:ok, {:already_member, building}} ->
        conn
        |> put_status(:ok)
        |> json(%{
          data: building_json(building),
          message: "already_member"
        })

      {:ok, {building, _member}} ->
        conn
        |> put_status(:created)
        |> json(%{data: building_json(building)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "invalid_code"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          errors: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
        })
    end
  end

  def join(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing_code"})
  end

  defp building_json(b) do
    %{
      id: b.id,
      name: b.name,
      address: b.address,
      city: b.city,
      postal_code: b.postal_code,
      lot_count: b.lot_count,
      cover_url: b.cover_url,
      role: :coproprietaire
    }
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
