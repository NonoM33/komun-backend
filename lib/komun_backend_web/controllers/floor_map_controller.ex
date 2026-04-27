defmodule KomunBackendWeb.FloorMapController do
  @moduledoc """
  Endpoints d'admin pour la cartographie des logements d'un bâtiment.

  - `GET /api/v1/buildings/:building_id/floor-map` — vue agrégée par étage,
    avec l'adjacence calculée (convention) + les overrides actuels.
  - `PATCH /api/v1/lots/:id/adjacency` — édition des overrides
    (`unit_below_lot_id`, `unit_above_lot_id`, `neighbor_lot_ids`).
  - `GET /api/v1/lots/:id/notify-preview?subtype=water_leak|noise` —
    preview de qui sera notifié si un incident de ce subtype est créé
    depuis ce logement (pour rassurer l'utilisateur côté UI).

  L'édition est réservée aux rôles `:super_admin` et `:syndic_manager` —
  pas aux membres du CS (la cartographie est une info officielle, le
  syndic doit en rester garant).
  """

  use KomunBackendWeb, :controller

  import Ecto.Query

  alias KomunBackend.{Buildings, Repo}
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.{Adjacency, BuildingMember, Lot}

  # Lecture : syndic + CS peuvent voir la cartographie pour comprendre les
  # alertes voisinage. Édition : restreint au syndic uniquement.
  @read_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]
  @edit_roles [:super_admin, :syndic_manager]

  # GET /api/v1/buildings/:building_id/floor-map
  def show(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize(conn, building_id, user, @read_roles, "Accès à la cartographie réservé") do
      lots =
        from(l in Lot,
          where: l.building_id == ^building_id,
          order_by: [desc: l.floor, asc: l.number]
        )
        |> Repo.all()

      members =
        from(m in BuildingMember,
          where: m.building_id == ^building_id and m.is_active == true,
          preload: [:user]
        )
        |> Repo.all()

      members_by_lot = Enum.group_by(members, & &1.primary_lot_id)

      payload =
        lots
        |> Enum.group_by(& &1.floor)
        |> Enum.sort_by(fn {floor, _} -> floor end, &>=/2)
        |> Enum.map(fn {floor, floor_lots} ->
          %{
            floor: floor,
            lots: Enum.map(floor_lots, &lot_json(&1, lots, members_by_lot))
          }
        end)

      json(conn, %{data: payload})
    end
  end

  # PATCH /api/v1/lots/:id/adjacency
  def update_adjacency(conn, %{"id" => lot_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    lot = Repo.get!(Lot, lot_id)

    with :ok <- authorize(conn, lot.building_id, user, @edit_roles,
                          "Édition réservée au syndic et super_admin") do
      attrs = %{
        "unit_below_lot_id" => params["unit_below_lot_id"],
        "unit_above_lot_id" => params["unit_above_lot_id"],
        "neighbor_lot_ids" => params["neighbor_lot_ids"] || []
      }

      case lot |> Lot.adjacency_changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          json(conn, %{data: lot_basic_json(updated)})

        {:error, cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
      end
    end
  end

  # GET /api/v1/lots/:id/notify-preview?subtype=water_leak
  def notify_preview(conn, %{"id" => lot_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    lot = Repo.get!(Lot, lot_id)

    with :ok <- authorize(conn, lot.building_id, user, @read_roles, "Accès réservé") do
      subtype = params["subtype"] || "water_leak"
      targets = preview_targets(lot, subtype)

      json(conn, %{
        data: %{
          subtype: subtype,
          targets:
            Enum.map(targets, fn {target_lot, members} ->
              %{
                lot: lot_basic_json(target_lot),
                members:
                  Enum.map(members, fn m ->
                    %{id: m.user.id, email: m.user.email, name: display_name(m.user)}
                  end)
              }
            end)
        }
      })
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp preview_targets(%Lot{} = lot, "water_leak") do
    case Adjacency.unit_below(lot) do
      nil -> []
      below -> [{below, Adjacency.members_for_lot(below)}]
    end
  end

  defp preview_targets(%Lot{} = lot, "noise") do
    Adjacency.same_floor_neighbors(lot)
    |> Enum.map(fn neighbor -> {neighbor, Adjacency.members_for_lot(neighbor)} end)
  end

  defp preview_targets(_lot, _other), do: []

  defp lot_json(%Lot{} = lot, all_lots, members_by_lot) do
    by_id = Map.new(all_lots, fn l -> {l.id, l} end)
    computed_below = if lot.floor, do: find_computed(lot, by_id, &(&1.floor == lot.floor - 1)), else: nil
    computed_above = if lot.floor, do: find_computed(lot, by_id, &(&1.floor == lot.floor + 1)), else: nil

    primary_member =
      members_by_lot
      |> Map.get(lot.id, [])
      |> List.first()

    %{
      id: lot.id,
      number: lot.number,
      floor: lot.floor,
      type: lot.type,
      computed_below: maybe_lot_ref(computed_below),
      computed_above: maybe_lot_ref(computed_above),
      override_below_id: lot.unit_below_lot_id,
      override_above_id: lot.unit_above_lot_id,
      override_neighbor_ids: lot.neighbor_lot_ids,
      primary_member: maybe_member_ref(primary_member)
    }
  end

  # Reproduit la convention "même colonne, étage cible" sans refaire de
  # requête SQL — on a déjà tous les lots du bâtiment chargés.
  defp find_computed(%Lot{} = lot, by_id, floor_pred) do
    case Adjacency.column_suffix(lot.number) do
      nil ->
        nil

      suffix ->
        by_id
        |> Map.values()
        |> Enum.find(fn l ->
          l.id != lot.id and
            l.type == :apartment and
            floor_pred.(l) and
            Adjacency.column_suffix(l.number) == suffix
        end)
    end
  end

  defp maybe_lot_ref(nil), do: nil
  defp maybe_lot_ref(%Lot{} = lot), do: %{id: lot.id, number: lot.number, floor: lot.floor}

  defp maybe_member_ref(nil), do: nil

  defp maybe_member_ref(%BuildingMember{user: user}) do
    %{id: user.id, name: display_name(user), email: user.email}
  end

  defp lot_basic_json(%Lot{} = lot) do
    %{
      id: lot.id,
      number: lot.number,
      floor: lot.floor,
      type: lot.type,
      override_below_id: lot.unit_below_lot_id,
      override_above_id: lot.unit_above_lot_id,
      override_neighbor_ids: lot.neighbor_lot_ids
    }
  end

  defp authorize(conn, building_id, user, allowed_roles, deny_message) do
    member_role = Buildings.get_member_role(building_id, user.id)

    cond do
      user.role == :super_admin -> :ok
      user.role in allowed_roles -> :ok
      member_role in allowed_roles -> :ok
      true ->
        conn |> put_status(:forbidden) |> json(%{error: deny_message}) |> halt()
    end
  end

  defp display_name(%{first_name: f, last_name: l}) when is_binary(f) and is_binary(l), do: "#{f} #{l}"
  defp display_name(%{first_name: f}) when is_binary(f), do: f
  defp display_name(%{email: e}), do: e

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
