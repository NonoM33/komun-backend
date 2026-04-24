defmodule KomunBackend.Buildings do
  @moduledoc "Buildings context — scoped by organization."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Audit
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
    attrs =
      attrs
      |> Map.put(:organization_id, org_id)
      |> ensure_join_code()
      |> ensure_residence()

    %Building{}
    |> Building.initial_changeset(attrs)
    |> Repo.insert()
  end

  # Admin version: organization_id optional.
  #
  # Depuis l'introduction des résidences, chaque bâtiment doit avoir une
  # `residence_id`. Si le caller n'en fournit pas, on auto-crée une résidence
  # mono-bâtiment avec les mêmes infos (name, address, city…) pour garder
  # l'ancien flow "créer un bâtiment en un clic" fonctionnel. L'admin peut
  # ensuite rattacher ce bâtiment à une autre résidence via l'UI.
  def create_building(attrs) when is_map(attrs) do
    attrs = ensure_join_code(attrs)
    attrs = ensure_residence(attrs)

    %Building{}
    |> Building.initial_changeset(attrs)
    |> Repo.insert()
  end

  defp ensure_residence(attrs) when is_map(attrs) do
    already? =
      Map.has_key?(attrs, :residence_id) or Map.has_key?(attrs, "residence_id")

    if already? do
      attrs
    else
      residence_attrs = %{
        name: Map.get(attrs, :name) || Map.get(attrs, "name"),
        address: Map.get(attrs, :address) || Map.get(attrs, "address"),
        city: Map.get(attrs, :city) || Map.get(attrs, "city"),
        postal_code: Map.get(attrs, :postal_code) || Map.get(attrs, "postal_code"),
        country: Map.get(attrs, :country) || Map.get(attrs, "country") || "FR",
        organization_id:
          Map.get(attrs, :organization_id) || Map.get(attrs, "organization_id")
      }

      case KomunBackend.Residences.create_residence(residence_attrs) do
        {:ok, residence} ->
          if Map.has_key?(attrs, :name),
            do: Map.put(attrs, :residence_id, residence.id),
            else: Map.put(attrs, "residence_id", residence.id)

        {:error, _} ->
          attrs
      end
    end
  end

  # Stuffs a fresh join_code into the attrs if the caller didn't provide one.
  # We accept both atom- and string-keyed maps since callers here aren't
  # consistent.
  defp ensure_join_code(attrs) when is_map(attrs) do
    has_code? = Map.has_key?(attrs, :join_code) or Map.has_key?(attrs, "join_code")

    if has_code? do
      attrs
    else
      cond do
        Map.has_key?(attrs, :organization_id) -> Map.put(attrs, :join_code, generate_join_code())
        true -> Map.put(attrs, "join_code", generate_join_code())
      end
    end
  end

  def update_building(building, attrs) do
    # Le `join_code` est explicitement strippé des attrs : même si un
    # caller distrait ou un client bogué l'envoie dans un PATCH, le code
    # n'est jamais remplacé en silence. Cf. règle dans CLAUDE.md (racine
    # du repo frontend).
    sanitized =
      attrs
      |> Map.delete(:join_code)
      |> Map.delete("join_code")

    building |> Building.changeset(sanitized) |> Repo.update()
  end

  @doc """
  Soft-delete d'un bâtiment : on marque `is_active=false` et on désactive
  aussi ses memberships. Tous les endpoints qui listent les bâtiments (par
  building_id scoped queries, `list_user_buildings`…) filtrent déjà sur
  `is_active == true`.

  Renvoie `{:error, :has_active_members}` si le bâtiment a encore des
  résidents actifs — le caller doit les déplacer ou les retirer d'abord.
  """
  def delete_building(building) do
    active_members =
      from(m in BuildingMember,
        where: m.building_id == ^building.id and m.is_active == true
      )
      |> Repo.aggregate(:count)

    cond do
      active_members > 0 ->
        {:error, :has_active_members}

      true ->
        building
        |> Ecto.Changeset.change(is_active: false)
        |> Repo.update()
    end
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

  @doc """
  Insère un nouveau membre. Retourne `{:error, :already_member}` si une
  ligne existe déjà pour `(building_id, user_id)` (active ou non).

  Le **changement de rôle** d'un membre existant doit passer par
  `set_member_role/4` — l'upsert destructif d'avant écrasait
  silencieusement le rôle (`president_cs` → `coproprietaire`) quand un
  caller appelait `add_member` avec le default. Voir le bug "rôles
  disparus au redéploiement" : la séparation insert / update est la
  défense en profondeur contre cette classe de régression.

  Options :
  - `:source` (atom) — origine de la mutation (cf. `KomunBackend.Audit`).
    Default `:manual`. Trace une ligne dans `role_audit_log`.
  - `:actor_id` — id de l'utilisateur qui a déclenché l'action (admin
    typiquement).
  - `:metadata` — map libre attachée à la trace.
  """
  def add_member(building_id, user_id, role \\ :coproprietaire, opts \\ []) do
    case Repo.get_by(BuildingMember, building_id: building_id, user_id: user_id) do
      nil ->
        result =
          %BuildingMember{}
          |> BuildingMember.changeset(%{
            building_id: building_id,
            user_id: user_id,
            role: role,
            is_active: true,
            joined_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
          |> Repo.insert()

        case result do
          {:ok, member} ->
            audit_role_change(opts, %{
              scope: :building,
              user_id: user_id,
              building_id: building_id,
              old_role: nil,
              new_role: member.role
            })

            {:ok, member}

          {:error, _} = err ->
            err
        end

      _existing ->
        {:error, :already_member}
    end
  end

  @doc """
  Met à jour le rôle d'un membre existant. Refuse `{:error, :not_found}`
  si la ligne n'existe pas — c'est volontaire : un changement de rôle ne
  doit jamais aussi servir d'insertion implicite.

  Réactive aussi la ligne (`is_active: true`) au passage, par cohérence
  avec l'idée que "set_role" implique que le membre est dans le
  bâtiment.

  Options : voir `add_member/4`.
  """
  def set_member_role(building_id, user_id, new_role, opts \\ []) do
    case Repo.get_by(BuildingMember, building_id: building_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      %BuildingMember{role: current_role} = member ->
        result =
          member
          |> BuildingMember.changeset(%{role: new_role, is_active: true})
          |> Repo.update()

        case result do
          {:ok, updated} ->
            audit_role_change(opts, %{
              scope: :building,
              user_id: user_id,
              building_id: building_id,
              old_role: current_role,
              new_role: updated.role
            })

            {:ok, updated}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Réactive un membre soft-désactivé sans toucher à son rôle. Utilisé par
  `join_by_code/3` quand on retrouve un ancien membre `is_active: false`
  — on ne veut **surtout pas** écraser son rôle d'origine en le
  re-insérant avec un default.
  """
  def reactivate_member(building_id, user_id) do
    case Repo.get_by(BuildingMember, building_id: building_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      %BuildingMember{is_active: true} = member ->
        {:ok, member}

      member ->
        member
        |> Ecto.Changeset.change(is_active: true)
        |> Repo.update()
    end
  end

  defp audit_role_change(opts, base_attrs) do
    Audit.record_role_change(
      Map.merge(base_attrs, %{
        source: Keyword.get(opts, :source, :manual),
        actor_id: Keyword.get(opts, :actor_id),
        metadata: Keyword.get(opts, :metadata, %{})
      })
    )
  end

  def remove_member(building_id, user_id, opts \\ []) do
    case Repo.get_by(BuildingMember, building_id: building_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      member ->
        case Repo.delete(member) do
          {:ok, deleted} ->
            audit_role_change(opts, %{
              scope: :building,
              user_id: user_id,
              building_id: building_id,
              old_role: deleted.role,
              new_role: nil
            })

            {:ok, deleted}

          {:error, _} = err ->
            err
        end
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

  @doc """
  Ajoute le user à l'immeuble via l'invite et incrémente used_count.
  Si l'user était déjà membre, on ne touche **pas** à son rôle existant
  — l'invite n'a pas vocation à downgrader/upgrader silencieusement
  quelqu'un — et on ne consomme pas un usage de l'invite.
  """
  def use_invite(invite, user_id) do
    Repo.transaction(fn ->
      role_atom = String.to_existing_atom(invite.role)

      case add_member(invite.building_id, user_id, role_atom, source: :join_by_code) do
        {:ok, member} ->
          invite
          |> BuildingInvite.changeset(%{used_count: invite.used_count + 1})
          |> Repo.update!()

          member

        {:error, :already_member} ->
          Repo.rollback(:already_member)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # ── Join by short code ────────────────────────────────────────────────────

  @join_code_alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @join_code_length 8

  @doc """
  Returns an uppercase alphanumeric join code of length `@join_code_length`,
  using an alphabet that excludes the ambiguous characters `0/O/1/I` to cut
  down on misreads from wall posters.
  """
  def generate_join_code do
    for _ <- 1..@join_code_length, into: "" do
      <<Enum.random(@join_code_alphabet)>>
    end
  end

  @doc "Fetches an active building by its join code. Case-insensitive."
  def get_building_by_join_code(code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    from(b in Building,
      where: b.join_code == ^normalized and b.is_active == true
    )
    |> Repo.one()
  end

  def get_building_by_join_code(_), do: nil

  @doc """
  Joins a user to a building via its short code.

  Returns:
  - `{:ok, {building, member}}` — the user is now an active member.
  - `{:ok, {:already_member, building}}` — the user was already a member;
    we just echo the building back.
  - `{:error, :not_found}` — no active building matches the code.
  - `{:error, changeset}` — membership insert failed.
  """
  def join_by_code(code, user_id, role \\ :coproprietaire) do
    case get_building_by_join_code(code) do
      nil ->
        {:error, :not_found}

      building ->
        existing = Repo.get_by(BuildingMember, building_id: building.id, user_id: user_id)

        cond do
          # Déjà membre actif : on ne touche à rien.
          match?(%BuildingMember{is_active: true}, existing) ->
            {:ok, {:already_member, building}}

          # Membre soft-désactivé (cas rare aujourd'hui mais possible si
          # un futur flow le fait) : on réactive en gardant son rôle
          # d'origine. SURTOUT PAS d'add_member ici : ça ré-écrirait le
          # rôle avec le default `role` du caller.
          match?(%BuildingMember{is_active: false}, existing) ->
            case reactivate_member(building.id, user_id) do
              {:ok, reactivated} ->
                Audit.record_role_change(%{
                  scope: :building,
                  source: :join_by_code,
                  user_id: user_id,
                  building_id: building.id,
                  old_role: nil,
                  new_role: reactivated.role,
                  metadata: %{reactivated: true}
                })

                {:ok, {:already_member, building}}

              {:error, cs} ->
                {:error, cs}
            end

          # Pas du tout membre : insertion classique.
          true ->
            case add_member(building.id, user_id, role, source: :join_by_code) do
              {:ok, member} -> {:ok, {building, member}}
              {:error, cs} -> {:error, cs}
            end
        end
    end
  end
end
