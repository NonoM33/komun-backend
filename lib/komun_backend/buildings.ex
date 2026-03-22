defmodule KomunBackend.Buildings do
  @moduledoc "Buildings context — scoped by organization."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Buildings.{Building, BuildingMember, Lot}

  def list_buildings(org_id) do
    from(b in Building,
      where: b.organization_id == ^org_id and b.is_active == true,
      order_by: [asc: b.name]
    )
    |> Repo.all()
  end

  def get_building!(id), do: Repo.get!(Building, id)

  def get_building_for_org!(org_id, id) do
    from(b in Building,
      where: b.id == ^id and b.organization_id == ^org_id
    )
    |> Repo.one!()
  end

  def create_building(org_id, attrs) do
    %Building{}
    |> Building.changeset(Map.put(attrs, :organization_id, org_id))
    |> Repo.insert()
  end

  # Admin version: organization_id optional
  def create_building(attrs) when is_map(attrs) do
    %Building{}
    |> Building.admin_changeset(attrs)
    |> Repo.insert()
  end

  def update_building(building, attrs) do
    building |> Building.changeset(attrs) |> Repo.update()
  end

  # ── Members ───────────────────────────────────────────────────────────────

  def member?(building_id, user_id) do
    from(m in BuildingMember,
      where: m.building_id == ^building_id and m.user_id == ^user_id and m.is_active == true
    )
    |> Repo.exists?()
  end

  def get_member_role(building_id, user_id) do
    from(m in BuildingMember,
      where: m.building_id == ^building_id and m.user_id == ^user_id and m.is_active == true,
      select: m.role
    )
    |> Repo.one()
  end

  def list_members(building_id) do
    from(m in BuildingMember,
      where: m.building_id == ^building_id and m.is_active == true,
      preload: :user,
      order_by: [asc: m.role]
    )
    |> Repo.all()
  end

  def add_member(building_id, user_id, role \\ :coproprietaire) do
    %BuildingMember{}
    |> BuildingMember.changeset(%{
      building_id: building_id,
      user_id: user_id,
      role: role,
      joined_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:building_id, :user_id])
  end

  def remove_member(building_id, user_id) do
    case Repo.get_by(BuildingMember, building_id: building_id, user_id: user_id) do
      nil -> {:error, :not_found}
      member -> Repo.delete(member)
    end
  end

  def list_all_buildings do
    Repo.all(Building)
  end

  # ── Lots ──────────────────────────────────────────────────────────────────

  def list_lots(building_id) do
    from(l in Lot,
      where: l.building_id == ^building_id,
      preload: [:owner, :tenant],
      order_by: [asc: l.number]
    )
    |> Repo.all()
  end

  def list_user_buildings(user_id) do
    from(m in BuildingMember,
      where: m.user_id == ^user_id and m.is_active == true,
      join: b in assoc(m, :building),
      where: b.is_active == true,
      select: {b, m.role},
      order_by: [asc: b.name]
    )
    |> Repo.all()
  end
end
