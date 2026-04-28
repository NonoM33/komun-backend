defmodule KomunBackend.Residences do
  @moduledoc """
  Contexte **Résidences** — la copropriété vue comme entité qui regroupe
  un ou plusieurs bâtiments.

  Deux niveaux d'invitation :
  - `join_code` de la résidence → l'user choisit son bâtiment à l'inscription
  - `join_code` du bâtiment → join direct

  `verify_code/1` résout un code en un de ces deux types sans que le caller
  ait besoin de savoir lequel c'est.
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Residences.Residence
  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.{Building, BuildingMember}

  # ── Codes (mêmes règles que Buildings pour rester cohérents) ─────────────

  @join_code_alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @join_code_length 8

  def generate_join_code do
    for _ <- 1..@join_code_length, into: "" do
      <<Enum.random(@join_code_alphabet)>>
    end
  end

  # ── Résidences — CRUD de base ─────────────────────────────────────────────

  def get_residence!(id), do: Repo.get!(Residence, id)

  def get_residence(id), do: Repo.get(Residence, id)

  @doc """
  Liste les `building_id` actifs d'une résidence.

  Utilisé par les endpoints qui agrègent des données d'une résidence
  via leurs bâtiments (ex. activité d'un voisin sur l'ensemble de la
  copro). Renvoie une liste vide si la résidence n'existe pas / est
  inactive — les callers décident s'ils transforment ça en 404.
  """
  def list_active_building_ids(residence_id) do
    from(b in Building,
      where: b.residence_id == ^residence_id and b.is_active == true,
      select: b.id
    )
    |> Repo.all()
  end

  @doc """
  Vrai si `user` est privilégié dans **au moins un** bâtiment actif de
  la résidence (ou est `super_admin` global). Sert à gater l'accès aux
  endpoints qui agrègent l'activité d'un autre voisin sur la résidence.

  Privilégiés : `super_admin`, `syndic_manager`, `syndic_staff`,
  `president_cs`, `membre_cs`.
  """
  def privileged_member?(_residence_id, nil), do: false

  def privileged_member?(_residence_id, %{role: :super_admin}), do: true

  def privileged_member?(residence_id, %{id: user_id, role: role}) do
    # Distinction importante : les rôles `:syndic_manager` / `:syndic_staff`
    # vivent sur User.role (rôle global, plateforme-wide), tandis que
    # `:president_cs` / `:membre_cs` sont sur BuildingMember.role (rôle
    # par bâtiment). On vérifie donc le rôle global d'abord — un syndic
    # est privilégié partout — puis on regarde si l'user a un rôle CS
    # dans au moins un bâtiment de la résidence.
    global_privileged = ~w(syndic_manager syndic_staff)a
    council_roles = ~w(president_cs membre_cs)a

    if role in global_privileged or role in council_roles do
      true
    else
      from(m in BuildingMember,
        join: b in Building,
        on: b.id == m.building_id,
        where:
          b.residence_id == ^residence_id and
            b.is_active == true and
            m.is_active == true and
            m.user_id == ^user_id and
            m.role in ^council_roles,
        select: 1,
        limit: 1
      )
      |> Repo.one()
      |> case do
        nil -> false
        _ -> true
      end
    end
  end

  def get_residence_with_buildings!(id) do
    Residence
    |> Repo.get!(id)
    |> Repo.preload(buildings: from(b in Building, where: b.is_active == true, order_by: [asc: b.name]))
  end

  def get_residence_by_join_code(code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    from(r in Residence,
      where: r.join_code == ^normalized and r.is_active == true
    )
    |> Repo.one()
  end

  def get_residence_by_join_code(_), do: nil

  def list_user_residences(user_id) do
    # Une résidence est "à l'user" si au moins un de ses bâtiments l'a comme
    # membre. On déduplique en GROUP BY et on remonte le rôle le plus privilégié
    # qu'il a dans cette résidence.
    from(r in Residence,
      join: b in Building,
      on: b.residence_id == r.id,
      join: m in BuildingMember,
      on: m.building_id == b.id and m.user_id == ^user_id and m.is_active == true,
      where: r.is_active == true,
      distinct: r.id,
      select: r
    )
    |> Repo.all()
    |> Repo.preload(
      buildings:
        from(b in Building,
          where: b.is_active == true,
          order_by: [asc: b.name]
        )
    )
  end

  def list_all_residences do
    Residence
    |> where([r], r.is_active == true)
    |> order_by(asc: :name)
    |> Repo.all()
    |> Repo.preload(
      buildings:
        from(b in Building,
          where: b.is_active == true,
          order_by: [asc: b.name]
        )
    )
  end

  def create_residence(attrs) do
    %Residence{}
    |> Residence.initial_changeset(ensure_join_code(attrs))
    |> Repo.insert()
  end

  @doc """
  Met à jour une résidence. Le `join_code` est volontairement strippé
  des attrs reçus AVANT le cast : même si un caller distrait ou un
  client bogué envoie `{ "join_code": "XXX" }` dans un PATCH, le code
  reste intact.

  Règle documentée dans `CLAUDE.md` à la racine du repo frontend.
  Si un jour on veut vraiment rotater un code, il faut une fonction
  dédiée (rotate_join_code) gated derrière un bouton DANGER admin —
  pas un PATCH /residences/:id banal.
  """
  def update_residence(%Residence{} = residence, attrs) do
    residence
    |> Residence.changeset(strip_join_code(attrs))
    |> Repo.update()
  end

  defp strip_join_code(attrs) when is_map(attrs) do
    attrs
    |> Map.delete(:join_code)
    |> Map.delete("join_code")
  end

  def delete_residence(%Residence{} = residence) do
    # Soft-delete : on désactive plutôt que de supprimer pour préserver les
    # références historiques (incidents, documents, etc.).
    residence
    |> Ecto.Changeset.change(is_active: false)
    |> Repo.update()
  end

  @doc """
  Liste tous les membres actifs d'une résidence, agrégés à travers
  tous ses bâtiments, dédupliqués par user_id. Le rôle remonté est le
  plus privilégié que l'user a dans la résidence (ex. `president_cs`
  prime sur `coproprietaire`).

  Usage : page "Voisins" côté front, qui doit afficher toutes les
  personnes de la copropriété — pas seulement celles du bâtiment
  courant du viewer.
  """
  def list_residence_members(residence_id) do
    # Priorité des rôles — plus haut = plus privilégié. Quand un user
    # est dans plusieurs bâtiments de la résidence avec des rôles
    # différents, on remonte le plus élevé.
    role_priority = fn role ->
      case role do
        :syndic_manager -> 100
        :syndic_staff -> 90
        :president_cs -> 80
        :membre_cs -> 70
        :council -> 65
        :super_admin -> 60
        :coproprietaire -> 50
        :locataire -> 40
        :gardien -> 30
        :prestataire -> 20
        _ -> 0
      end
    end

    rows =
      from(m in BuildingMember,
        join: b in Building,
        on: b.id == m.building_id,
        where:
          b.residence_id == ^residence_id and
            b.is_active == true and
            m.is_active == true,
        preload: :user
      )
      |> Repo.all()

    rows
    |> Enum.group_by(& &1.user_id)
    |> Enum.map(fn {_uid, memberships} ->
      # Pick the most privileged membership for this user
      Enum.max_by(memberships, fn m -> role_priority.(m.role) end)
    end)
    |> Enum.sort_by(fn m ->
      {-role_priority.(m.role),
       String.downcase(m.user.last_name || m.user.email || "")}
    end)
  end

  @doc """
  Absorbe toutes les résidences sources dans la résidence cible :
  déplace chaque bâtiment actif vers la cible, puis soft-delete les
  résidences sources une fois qu'elles sont vides.

  Renvoie `{:ok, %{moved: n, deleted: m}}`.
  """
  def merge_into(target_residence_id, source_residence_ids) when is_list(source_residence_ids) do
    sources = Enum.reject(source_residence_ids, &(&1 == target_residence_id))

    Repo.transaction(fn ->
      moved =
        from(b in Building,
          where: b.residence_id in ^sources and b.is_active == true
        )
        |> Repo.update_all(set: [residence_id: target_residence_id, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])
        |> elem(0)

      deleted =
        from(r in Residence, where: r.id in ^sources and r.is_active == true)
        |> Repo.update_all(set: [is_active: false, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])
        |> elem(0)

      %{moved: moved, deleted: deleted}
    end)
  end

  # ── Rattachement de bâtiments ─────────────────────────────────────────────

  @doc """
  Rattache un bâtiment à une résidence. On vérifie simplement que les deux
  existent — le caller (controller) est responsable de la permission.
  """
  def attach_building(residence_id, building_id) do
    case Buildings.get_building!(building_id) do
      %Building{} = building ->
        building
        |> Ecto.Changeset.change(residence_id: residence_id)
        |> Repo.update()
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  # ── Verify unifié (résidence OU bâtiment) ────────────────────────────────

  @doc """
  Résout un code en résidence (→ liste de bâtiments à choisir) ou en
  bâtiment direct (→ join one-click).

  Retourne :
  - `{:residence, residence, buildings}` — code résidence valide
  - `{:building, building, residence}` — code bâtiment valide
  - `:not_found` — aucun code ne matche
  """
  def verify_code(code) when is_binary(code) do
    normalized = code |> String.trim() |> String.upcase()

    case get_residence_by_join_code(normalized) do
      %Residence{} = residence ->
        residence = Repo.preload(residence,
          buildings: from(b in Building, where: b.is_active == true, order_by: [asc: b.name])
        )

        {:residence, residence, residence.buildings}

      nil ->
        case Buildings.get_building_by_join_code(normalized) do
          %Building{} = building ->
            residence =
              if building.residence_id, do: get_residence(building.residence_id), else: nil

            {:building, building, residence}

          nil ->
            :not_found
        end
    end
  end

  def verify_code(_), do: :not_found

  # ── Helpers internes ──────────────────────────────────────────────────────

  defp ensure_join_code(attrs) when is_map(attrs) do
    has_code? = Map.has_key?(attrs, :join_code) or Map.has_key?(attrs, "join_code")

    cond do
      has_code? -> attrs
      Map.has_key?(attrs, :name) -> Map.put(attrs, :join_code, generate_join_code())
      true -> Map.put(attrs, "join_code", generate_join_code())
    end
  end
end
