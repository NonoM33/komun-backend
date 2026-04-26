defmodule KomunBackend.Buildings.Adjacency do
  @moduledoc """
  Calcule l'adjacence entre logements (logement en dessous, en dessus,
  voisins de palier) pour router les notifications d'incidents de voisinage.

  Stratégie en deux temps :

  1. **Override manuel** — si le syndic a saisi un override sur le `Lot`
     (`unit_below_lot_id`, `unit_above_lot_id`, `neighbor_lot_ids`), il prime
     toujours. C'est la source de vérité quand la convention casse.

  2. **Convention de numérotation** — sinon on déduit du `lot.number`. La
     règle par défaut traite les 3 derniers chiffres comme la "colonne"
     (position verticale dans l'immeuble) et le préfixe comme l'étage :

         "2003" → étage 2, colonne 003 → en dessous = "1003"
         "1A04" → pas de match, retourne nil

  Les fonctions retournent toujours un `%Lot{}` (ou liste de) **du même
  bâtiment** que le lot en entrée. On ne traverse jamais les bâtiments :
  un dégât des eaux dans le bâtiment B ne notifie personne dans le A.
  """

  import Ecto.Query

  alias KomunBackend.Buildings.{Lot, BuildingMember}
  alias KomunBackend.Repo

  # Regex de la convention par défaut : on capture le préfixe et les 3
  # derniers chiffres. La string doit être strictement numérique.
  @column_suffix_length 3
  @number_regex ~r/^(\d+?)(\d{#{@column_suffix_length}})$/

  @doc """
  Extrait la "colonne" depuis un numéro de logement, ou nil si la
  convention ne s'applique pas.

      iex> Adjacency.column_suffix("2003")
      "003"
      iex> Adjacency.column_suffix("A12")
      nil
      iex> Adjacency.column_suffix(nil)
      nil
  """
  def column_suffix(number) when is_binary(number) do
    case Regex.run(@number_regex, number) do
      [_, _floor_prefix, suffix] -> suffix
      _ -> nil
    end
  end

  def column_suffix(_), do: nil

  @doc """
  Logement directement en dessous du `lot`.

  - Override `unit_below_lot_id` si présent.
  - Sinon convention : même `column_suffix`, `floor = lot.floor - 1`,
    même bâtiment, type `:apartment`.
  - nil si aucun candidat.
  """
  def unit_below(%Lot{unit_below_lot_id: id}) when is_binary(id), do: Repo.get(Lot, id)
  def unit_below(%Lot{floor: nil}), do: nil
  def unit_below(%Lot{} = lot), do: find_by_convention(lot, lot.floor - 1)

  @doc "Logement directement en dessus — symétrique de unit_below/1."
  def unit_above(%Lot{unit_above_lot_id: id}) when is_binary(id), do: Repo.get(Lot, id)
  def unit_above(%Lot{floor: nil}), do: nil
  def unit_above(%Lot{} = lot), do: find_by_convention(lot, lot.floor + 1)

  defp find_by_convention(%Lot{} = lot, target_floor) do
    case column_suffix(lot.number) do
      nil ->
        nil

      suffix ->
        from(l in Lot,
          where:
            l.building_id == ^lot.building_id and
              l.floor == ^target_floor and
              l.type == :apartment and
              l.id != ^lot.id and
              fragment("? ~ ?", l.number, ^"^[0-9]+#{suffix}$")
        )
        |> Repo.all()
        |> Enum.find(fn candidate -> column_suffix(candidate.number) == suffix end)
    end
  end

  @doc """
  Voisins de palier (même étage, sauf le lot lui-même).

  - Si `neighbor_lot_ids` est non vide → on l'utilise comme override strict.
  - Sinon on retourne tous les `:apartment` du même `floor` dans le même
    bâtiment.
  """
  def same_floor_neighbors(%Lot{} = lot) do
    case lot.neighbor_lot_ids do
      [] -> default_same_floor_neighbors(lot)
      ids when is_list(ids) -> Repo.all(from(l in Lot, where: l.id in ^ids))
    end
  end

  defp default_same_floor_neighbors(%Lot{floor: nil}), do: []

  defp default_same_floor_neighbors(%Lot{} = lot) do
    from(l in Lot,
      where:
        l.building_id == ^lot.building_id and
          l.floor == ^lot.floor and
          l.type == :apartment and
          l.id != ^lot.id,
      order_by: [asc: l.number]
    )
    |> Repo.all()
  end

  @doc """
  Liste les `BuildingMember` actifs dont le `primary_lot_id` est ce lot.
  Préchargés avec `:user` pour permettre l'envoi d'emails / push.
  """
  def members_for_lot(%Lot{id: lot_id}) do
    from(m in BuildingMember,
      where: m.primary_lot_id == ^lot_id and m.is_active == true,
      preload: [:user]
    )
    |> Repo.all()
  end

  def members_for_lot(nil), do: []
end
