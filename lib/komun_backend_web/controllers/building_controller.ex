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
  # Any authenticated user can redeem a short code. The membership role
  # défaut au `users.role` global (= choix fait à l'inscription :
  # locataire, copropriétaire…). Avant on forçait `:coproprietaire`,
  # ce qui faisait que tous les locataires fraîchement inscrits
  # devenaient copropriétaires sans le savoir.
  #
  # Les rôles `super_admin` / `syndic_*` ne sont pas valables comme
  # rôle de bâtiment (le schéma BuildingMember ne les accepte pas) :
  # on retombe dans ce cas sur `:coproprietaire`. Les syndics et CS
  # présidents continuent d'onboarder via le flow invite-token dédié
  # qui leur attribue explicitement le bon rôle.
  def join(conn, %{"code" => code}) when is_binary(code) do
    user = Guardian.Plug.current_resource(conn)
    member_role = global_role_to_member_role(user.role)

    case Buildings.join_by_code(code, user.id, member_role) do
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

  # DELETE /api/v1/buildings/:id
  # Soft-delete d'un bâtiment. Refusé s'il reste des membres actifs
  # (→ 422 `{error: "has_active_members"}`). Pensé pour nettoyer les
  # bâtiments placeholder créés par la migration vers le modèle Résidence.
  def delete(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    if user.role == :super_admin or user.role in [:president_cs, :membre_cs, :syndic_manager, :syndic_staff, :council] do
      building = Buildings.get_building!(id)

      case Buildings.delete_building(building) do
        {:ok, _} -> json(conn, %{ok: true})

        {:error, :has_active_members} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            error: "has_active_members",
            message: "Ce bâtiment a encore des résidents. Déplacez-les ou retirez-les d'abord."
          })

        {:error, cs} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)})
      end
    else
      conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
    end
  rescue
    Ecto.NoResultsError ->
      conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end

  def lots(conn, %{"id" => id}) do
    lots = Buildings.list_lots(id)
    json(conn, %{data: Enum.map(lots, fn l ->
      %{id: l.id, number: l.number, type: l.type, floor: l.floor,
        area_sqm: l.area_sqm, tantieme: l.tantieme, is_occupied: l.is_occupied}
    end)})
  end

  # `users.role` peut valoir `:super_admin`, `:syndic_manager`, `:syndic_staff`
  # qui ne sont pas des rôles de bâtiment valides — pour ceux-là on retombe
  # sur `:coproprietaire`. Les autres rôles (locataire, copropriétaire,
  # gardien, prestataire, président_cs, membre_cs) sont communs aux deux
  # schémas et passent tels quels.
  @member_role_set MapSet.new([
    :coproprietaire,
    :locataire,
    :gardien,
    :prestataire,
    :president_cs,
    :membre_cs
  ])

  defp global_role_to_member_role(role) when is_atom(role) do
    if MapSet.member?(@member_role_set, role), do: role, else: :coproprietaire
  end

  defp global_role_to_member_role(role) when is_binary(role) do
    role |> String.to_existing_atom() |> global_role_to_member_role()
  rescue
    ArgumentError -> :coproprietaire
  end

  defp global_role_to_member_role(_), do: :coproprietaire
end
