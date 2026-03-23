defmodule KomunBackend.Buildings do
  @moduledoc "Buildings context — scoped by organization."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Buildings.{Building, BuildingInvite, BuildingMember, Lot}

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
    |> Repo.insert(
      on_conflict: {:replace, [:role, :is_active, :joined_at, :updated_at]},
      conflict_target: [:building_id, :user_id]
    )
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

  # ── Invites ────────────────────────────────────────────────────────────────

  @doc "Crée une invitation pour un immeuble. opts: role, max_uses, expires_in_days."
  def create_invite(building_id, user_id, opts \\ []) do
    token = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    role = Keyword.get(opts, :role, "coproprietaire")
    max_uses = Keyword.get(opts, :max_uses, nil)

    expires_at =
      case Keyword.get(opts, :expires_in_days) do
        nil -> nil
        days -> DateTime.utc_now() |> DateTime.add(days * 86_400, :second) |> DateTime.truncate(:second)
      end

    %BuildingInvite{}
    |> BuildingInvite.changeset(%{
      token: token,
      building_id: building_id,
      created_by_id: user_id,
      role: role,
      max_uses: max_uses,
      expires_at: expires_at
    })
    |> Repo.insert()
  end

  @doc "Récupère une invite active non expirée par son token."
  def get_invite_by_token(token) do
    now = DateTime.utc_now()

    from(i in BuildingInvite,
      where: i.token == ^token and i.is_active == true,
      where: is_nil(i.expires_at) or i.expires_at > ^now,
      where: is_nil(i.max_uses) or i.used_count < i.max_uses,
      preload: :building
    )
    |> Repo.one()
  end

  @doc "Ajoute le user à l'immeuble via l'invite et incrémente used_count."
  def use_invite(invite, user_id) do
    Repo.transaction(fn ->
      case add_member(invite.building_id, user_id, String.to_existing_atom(invite.role)) do
        {:ok, member} ->
          invite
          |> BuildingInvite.changeset(%{used_count: invite.used_count + 1})
          |> Repo.update!()

          member

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end
end
