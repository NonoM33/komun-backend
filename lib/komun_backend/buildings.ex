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
          # Building auto-créé via le path "résidence-clonée-du-name" :
          # par construction c'est un placeholder. Flag posé dès la
          # création pour qu'on n'ait pas à backfill plus tard si
          # quelqu'un ajoute un vrai bâtiment à côté. On respecte le
          # style de clés du caller (atom vs string) pour ne pas casser
          # le `cast` du changeset, qui refuse les maps mixtes.
          attrs
          |> put_attr(:residence_id, residence.id)
          |> put_attr(:is_placeholder, true)

        {:error, _} ->
          attrs
      end
    end
  end

  defp put_attr(attrs, key, value) when is_atom(key) do
    if Map.has_key?(attrs, key) or has_atom_keys?(attrs) do
      Map.put(attrs, key, value)
    else
      Map.put(attrs, to_string(key), value)
    end
  end

  defp has_atom_keys?(attrs) do
    Enum.any?(Map.keys(attrs), &is_atom/1)
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

  @doc """
  Amorce les `Lot` d'un bâtiment à partir de `floors` × `lots_per_floor`.

  La numérotation suit la convention utilisée par `Adjacency` :
  `"{floor}{column_suffix}"` où `column_suffix` est sur 3 chiffres
  zero-paddés (`"001"`..`"NNN"`). Exemple : `floors: 2, lots_per_floor: 3,
  start_floor: 1` produit `["1001", "1002", "1003", "2001", "2002", "2003"]`,
  donc la convention `2003 → 1003` fonctionne hors du bouge.

  Refuse (`{:error, :lots_already_exist}`) si le bâtiment a déjà au moins
  un lot — l'amorçage est strictement initial. Pour ajouter des logements
  ensuite, il faudra une autre fonction (à la main pour l'instant).

  Bornes :

  - `floors >= 1`
  - `lots_per_floor >= 1`
  - `lots_per_floor <= 999` (3 chiffres dans le suffixe — le regex de
    `Adjacency.column_suffix/1` n'en accepte pas plus)
  - total `floors * lots_per_floor <= 1000` (garde-fou sécurité bdd)

  Tout est inséré dans une transaction — si une seule insertion casse,
  rien n'est commité.
  """
  def generate_lots(%Building{} = building, opts) when is_map(opts) do
    floors = Map.get(opts, :floors) |> to_int()
    lots_per_floor = Map.get(opts, :lots_per_floor) |> to_int()
    start_floor = Map.get(opts, :start_floor, 1) |> to_int(default: 1)

    cond do
      not is_integer(floors) or floors < 1 ->
        {:error, :invalid_floors}

      not is_integer(lots_per_floor) or lots_per_floor < 1 ->
        {:error, :invalid_lots_per_floor}

      lots_per_floor > 999 ->
        {:error, :too_many_lots_per_floor}

      floors * lots_per_floor > 1000 ->
        {:error, :too_many_lots_total}

      Repo.exists?(from(l in Lot, where: l.building_id == ^building.id)) ->
        {:error, :lots_already_exist}

      true ->
        Repo.transaction(fn ->
          for floor <- start_floor..(start_floor + floors - 1),
              column <- 1..lots_per_floor do
            number =
              "#{floor}#{column |> Integer.to_string() |> String.pad_leading(3, "0")}"

            %Lot{}
            |> Lot.changeset(%{
              number: number,
              type: :apartment,
              floor: floor,
              building_id: building.id
            })
            |> Repo.insert!()
          end
        end)
        |> case do
          {:ok, _} -> {:ok, list_lots(building.id)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Supprime un `Lot` du bâtiment.

  Utilisé par `/admin/floor-map` quand le grid généré ne correspond pas
  exactement à la réalité — typiquement un RDC qui a moins de logements
  que les étages courants, ou une cellule "fantôme" créée par la
  génération automatique.

  Cascade BDD :
  - `building_members.primary_lot_id` → `nilify_all` (le membre reste,
    il perd juste son rattachement à ce lot).
  - `lots.unit_below_lot_id` / `unit_above_lot_id` → `nilify_all` (les
    overrides d'adjacence pointant vers ce lot redeviennent vides).
  - `reservations.lot_id` → `delete_all` (les résas sur ce lot tombent —
    pertinent pour les places de parking supprimées).

  Nettoyage manuel : `neighbor_lot_ids` (array de FK sans contrainte BDD)
  est rincé sur les autres lots du même bâtiment qui pourraient encore
  référencer ce lot — sinon l'`Adjacency` continuerait à essayer de
  notifier un lot mort.
  """
  def delete_lot(%Lot{id: lot_id, building_id: building_id} = lot) do
    Repo.transaction(fn ->
      from(l in Lot,
        where:
          l.building_id == ^building_id and
            fragment("? = ANY(?)", type(^lot_id, :binary_id), l.neighbor_lot_ids),
        update: [
          set: [
            neighbor_lot_ids:
              fragment("array_remove(?, ?)", l.neighbor_lot_ids, type(^lot_id, :binary_id))
          ]
        ]
      )
      |> Repo.update_all([])

      case Repo.delete(lot) do
        {:ok, deleted} -> deleted
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Supprime tous les lots d'un étage donné dans un bâtiment.

  Utilisé quand un étage entier a été généré par erreur — typiquement
  l'utilisateur a tapé "5" au lieu de "4" dans le formulaire et veut
  retirer le 5e étage en entier sans le faire lot par lot.

  Mêmes garanties de nettoyage que `delete_lot/1` :
  - on rince `neighbor_lot_ids` des autres lots du bâtiment qui
    référenceraient un des lots supprimés (Postgres `array_diff` via
    `array(... EXCEPT ...)`),
  - les FK BDD font le reste (overrides nilifiés, primary_lot nilifié,
    réservations supprimées).

  Renvoie `{:ok, count}` (nombre de lots supprimés, possiblement 0) ou
  `{:error, reason}`.
  """
  def delete_floor(%Building{id: building_id}, floor) when is_integer(floor) do
    deleted_ids =
      from(l in Lot,
        where: l.building_id == ^building_id and l.floor == ^floor,
        select: l.id
      )
      |> Repo.all()

    if deleted_ids == [] do
      {:ok, 0}
    else
      Repo.transaction(fn ->
        from(l in Lot,
          where:
            l.building_id == ^building_id and l.floor != ^floor and
              fragment("? && ?", l.neighbor_lot_ids, type(^deleted_ids, {:array, :binary_id})),
          update: [
            set: [
              neighbor_lot_ids:
                fragment(
                  "ARRAY(SELECT unnest(?) EXCEPT SELECT unnest(?))",
                  l.neighbor_lot_ids,
                  type(^deleted_ids, {:array, :binary_id})
                )
            ]
          ]
        )
        |> Repo.update_all([])

        {count, _} =
          from(l in Lot,
            where: l.building_id == ^building_id and l.floor == ^floor
          )
          |> Repo.delete_all()

        count
      end)
    end
  end

  @doc """
  Vide la cartographie : supprime TOUS les lots d'un bâtiment.

  Action de réinitialisation à utiliser quand le grid généré ne
  ressemble en rien à la réalité et que le syndic préfère repartir
  de zéro plutôt que de bricoler lot par lot. À gater côté UI par
  une confirmation forte (retape du nom du bâtiment).

  Aucun nettoyage `neighbor_lot_ids` nécessaire — toutes les lignes
  partent. Les FK BDD nilifient les `primary_lot_id` des membres
  et suppriment les réservations.

  Renvoie `{:ok, count}` (nombre de lots supprimés).
  """
  def delete_all_lots(%Building{id: building_id}) do
    {count, _} =
      from(l in Lot, where: l.building_id == ^building_id)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Pose ou retire l'étiquette personnalisée d'un étage du bâtiment.

  - `label = "..."` : enregistre l'override (`floor_labels["3"] = "..."`).
  - `label = nil` ou `""` : retire l'override (le frontend retombera sur
    l'étiquette calculée par défaut depuis l'entier `floor`).

  La clé est stringifiée — le champ `floor_labels` est un :map sérialisé
  en JSONB côté Postgres, donc les clés sont obligatoirement des strings.
  """
  def set_floor_label(%Building{} = building, floor, label) when is_integer(floor) do
    key = Integer.to_string(floor)
    trimmed = if is_binary(label), do: String.trim(label), else: nil

    new_labels =
      cond do
        trimmed in [nil, ""] -> Map.delete(building.floor_labels || %{}, key)
        true -> Map.put(building.floor_labels || %{}, key, trimmed)
      end

    building
    |> Building.floor_labels_changeset(new_labels)
    |> Repo.update()
  end

  defp to_int(value, opts \\ [])
  defp to_int(nil, opts), do: Keyword.get(opts, :default)
  defp to_int(value, _opts) when is_integer(value), do: value

  defp to_int(value, opts) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> Keyword.get(opts, :default)
    end
  end

  defp to_int(_, opts), do: Keyword.get(opts, :default)

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
