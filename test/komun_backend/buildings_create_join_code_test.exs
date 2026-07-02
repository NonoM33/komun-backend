defmodule KomunBackend.BuildingsCreateJoinCodeTest do
  use KomunBackend.DataCase, async: false

  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.Building

  # Non-régression : `ensure_join_code/1` insérait une clé string "join_code"
  # dans une map à clés atomes quand le caller ne passait pas d'`organization_id`
  # (le flow admin `create_building/1`). La map mixte faisait exploser `cast/3`
  # avec `Ecto.CastError: mixed keys`. Le fix aligne `ensure_join_code/1` sur
  # `put_attr/3` : il détecte le type de clés et injecte une clé du même type.
  describe "create_building/1 (admin, atom-keyed attrs sans organization_id)" do
    test "ne lève pas Ecto.CastError et génère un join_code" do
      attrs = %{
        name: "Résidence Sans Org #{System.unique_integer([:positive])}",
        address: "12 rue des Voisins",
        city: "Paris",
        postal_code: "75011"
      }

      assert {:ok, %Building{} = building} = Buildings.create_building(attrs)
      assert is_binary(building.join_code)
      assert String.length(building.join_code) == 8
    end
  end
end
