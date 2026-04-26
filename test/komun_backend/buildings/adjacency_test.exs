defmodule KomunBackend.Buildings.AdjacencyTest do
  @moduledoc """
  Tests TDD du module Adjacency : convention "2003 → 1003", overrides
  manuels, voisins de palier, résolution des membres.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.{Adjacency, Building, Lot}
  alias KomunBackend.Residences
  alias KomunBackend.Residences.Residence
  alias KomunBackend.Accounts.User

  defp insert_residence! do
    {:ok, r} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: "Résidence #{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> Repo.insert()

    r
  end

  defp insert_building!(residence, attrs \\ %{}) do
    defaults = %{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "1 rue du Test",
      city: "Paris",
      postal_code: "75001",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    }

    %Building{}
    |> Building.initial_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_lot!(building, attrs) do
    defaults = %{type: :apartment, building_id: building.id}

    %Lot{}
    |> Lot.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_user!() do
    %User{}
    |> User.changeset(%{
      email: "u#{System.unique_integer([:positive])}@test.local",
      role: :coproprietaire
    })
    |> Repo.insert!()
  end

  describe "column_suffix/1" do
    test "extrait les 3 derniers chiffres d'un numéro pur" do
      assert Adjacency.column_suffix("2003") == "003"
      assert Adjacency.column_suffix("1003") == "003"
      assert Adjacency.column_suffix("12345") == "345"
    end

    test "retourne nil quand le numéro contient des lettres" do
      assert Adjacency.column_suffix("A12") == nil
      assert Adjacency.column_suffix("2A03") == nil
      assert Adjacency.column_suffix("RDC1") == nil
    end

    test "retourne nil pour les inputs invalides" do
      assert Adjacency.column_suffix(nil) == nil
      assert Adjacency.column_suffix("") == nil
      assert Adjacency.column_suffix(2003) == nil
    end

    test "retourne nil quand le numéro est trop court (< 4 chiffres)" do
      # 3 chiffres seulement = pas de préfixe d'étage clair, on n'invente pas.
      assert Adjacency.column_suffix("003") == nil
    end
  end

  describe "unit_below/1 — convention par défaut" do
    test "trouve le logement de l'étage en dessous avec même colonne" do
      r = insert_residence!()
      b = insert_building!(r)

      _lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})
      _lot_1002 = insert_lot!(b, %{number: "1002", floor: 1})
      _lot_2002 = insert_lot!(b, %{number: "2002", floor: 2})

      lot_2003 = Repo.get_by(Lot, number: "2003", building_id: b.id)
      assert %Lot{id: id} = Adjacency.unit_below(lot_2003)
      assert id == lot_1003.id
    end

    test "retourne nil quand pas de candidat à l'étage du dessous" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      _autre = insert_lot!(b, %{number: "1004", floor: 1})

      assert Adjacency.unit_below(lot_2003) == nil
    end

    test "retourne nil quand le numéro ne matche pas la convention" do
      r = insert_residence!()
      b = insert_building!(r)

      lot = insert_lot!(b, %{number: "A12", floor: 2})
      _below = insert_lot!(b, %{number: "A11", floor: 1})

      assert Adjacency.unit_below(lot) == nil
    end

    test "ne traverse pas les bâtiments" do
      r = insert_residence!()
      b1 = insert_building!(r)
      b2 = insert_building!(r)

      lot_b1 = insert_lot!(b1, %{number: "2003", floor: 2})
      _lot_b2 = insert_lot!(b2, %{number: "1003", floor: 1})

      assert Adjacency.unit_below(lot_b1) == nil
    end
  end

  describe "unit_below/1 — override manuel" do
    test "respecte unit_below_lot_id même si la convention pointerait ailleurs" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_1002 = insert_lot!(b, %{number: "1002", floor: 1})
      lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})
      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})

      # Override : 2003 est en dessus de 1002 (et NON 1003 comme la convention).
      lot_2003
      |> Lot.adjacency_changeset(%{unit_below_lot_id: lot_1002.id})
      |> Repo.update!()

      reloaded = Repo.get(Lot, lot_2003.id)
      assert %Lot{id: id} = Adjacency.unit_below(reloaded)
      assert id == lot_1002.id

      # Vérifie qu'on n'a pas touché à 1003 par accident.
      assert Repo.get(Lot, lot_1003.id).id == lot_1003.id
    end
  end

  describe "unit_above/1" do
    test "trouve le logement de l'étage du dessus par convention" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})

      lot_1003 = Repo.get(Lot, lot_1003.id)
      assert %Lot{id: id} = Adjacency.unit_above(lot_1003)
      assert id == lot_2003.id
    end

    test "respecte l'override unit_above_lot_id" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})
      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      lot_2002 = insert_lot!(b, %{number: "2002", floor: 2})

      lot_1003
      |> Lot.adjacency_changeset(%{unit_above_lot_id: lot_2002.id})
      |> Repo.update!()

      reloaded = Repo.get(Lot, lot_1003.id)
      assert %Lot{id: id} = Adjacency.unit_above(reloaded)
      assert id == lot_2002.id
      refute id == lot_2003.id
    end
  end

  describe "same_floor_neighbors/1" do
    test "retourne tous les apartements de l'étage sauf le lot lui-même" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      lot_2002 = insert_lot!(b, %{number: "2002", floor: 2})
      lot_2004 = insert_lot!(b, %{number: "2004", floor: 2})
      _lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})

      neighbors = Adjacency.same_floor_neighbors(lot_2003)
      ids = Enum.map(neighbors, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([lot_2002.id, lot_2004.id])
    end

    test "exclut les non-apartments (parking, storage, etc.)" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      _parking = insert_lot!(b, %{number: "P201", floor: 2, type: :parking})
      _storage = insert_lot!(b, %{number: "C12", floor: 2, type: :storage})

      assert Adjacency.same_floor_neighbors(lot_2003) == []
    end

    test "respecte l'override neighbor_lot_ids" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_a = insert_lot!(b, %{number: "2001", floor: 2})
      lot_b = insert_lot!(b, %{number: "2002", floor: 2})
      lot_c = insert_lot!(b, %{number: "2003", floor: 2})

      # Override : a n'a que b comme voisin (pas c, même s'il est sur l'étage).
      lot_a
      |> Lot.adjacency_changeset(%{neighbor_lot_ids: [lot_b.id]})
      |> Repo.update!()

      reloaded = Repo.get(Lot, lot_a.id)
      neighbors = Adjacency.same_floor_neighbors(reloaded)
      assert Enum.map(neighbors, & &1.id) == [lot_b.id]
      refute Enum.any?(neighbors, fn n -> n.id == lot_c.id end)
    end
  end

  describe "members_for_lot/1" do
    test "retourne les membres actifs liés au lot via primary_lot_id" do
      r = insert_residence!()
      b = insert_building!(r)
      lot = insert_lot!(b, %{number: "2003", floor: 2})

      user_1 = insert_user!()
      user_2 = insert_user!()

      {:ok, m1} = Buildings.add_member(b.id, user_1.id, :coproprietaire)

      m1
      |> Ecto.Changeset.change(primary_lot_id: lot.id)
      |> Repo.update!()

      # m2 sans primary_lot_id → exclu
      {:ok, _m2} = Buildings.add_member(b.id, user_2.id, :coproprietaire)

      members = Adjacency.members_for_lot(lot)
      assert length(members) == 1
      assert hd(members).user_id == user_1.id
    end

    test "exclut les membres désactivés (is_active = false)" do
      r = insert_residence!()
      b = insert_building!(r)
      lot = insert_lot!(b, %{number: "2003", floor: 2})
      user = insert_user!()

      {:ok, m} = Buildings.add_member(b.id, user.id, :coproprietaire)

      m
      |> Ecto.Changeset.change(primary_lot_id: lot.id, is_active: false)
      |> Repo.update!()

      assert Adjacency.members_for_lot(lot) == []
    end

    test "retourne [] pour un lot nil" do
      assert Adjacency.members_for_lot(nil) == []
    end
  end
end
