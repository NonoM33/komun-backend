defmodule KomunBackend.ResidencesTest do
  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Residences, Buildings}
  alias KomunBackend.Residences.Residence
  alias KomunBackend.Buildings.Building

  defp insert_residence!(attrs \\ %{}) do
    defaults = %{
      name: "Les Hortensias #{System.unique_integer([:positive])}",
      address: "1 rue des Lilas",
      city: "Paris",
      postal_code: "75015"
    }

    {:ok, residence} =
      %Residence{}
      |> Residence.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    residence
  end

  defp insert_building!(residence, attrs \\ %{}) do
    defaults = %{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "2 rue des Lilas",
      city: "Paris",
      postal_code: "75015",
      residence_id: residence.id,
      join_code: Residences.generate_join_code()
    }

    %Building{}
    |> Building.admin_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  describe "create_residence/1" do
    test "auto-génère un join_code unique quand non fourni" do
      {:ok, r1} = Residences.create_residence(%{name: "Résidence Un"})
      {:ok, r2} = Residences.create_residence(%{name: "Résidence Deux"})

      assert is_binary(r1.join_code)
      assert String.length(r1.join_code) == 8
      refute r1.join_code == r2.join_code
    end

    test "rejette les noms trop courts" do
      assert {:error, cs} = Residences.create_residence(%{name: "x"})
      assert %{name: _} = errors_on(cs)
    end

    test "calcule un slug à partir du nom" do
      {:ok, r} = Residences.create_residence(%{name: "Les  Hortensias ! 75015"})
      assert r.slug == "les-hortensias-75015"
    end
  end

  describe "verify_code/1" do
    test "reconnaît un code résidence et retourne ses bâtiments" do
      residence = insert_residence!()
      b1 = insert_building!(residence, %{name: "Bât A"})
      b2 = insert_building!(residence, %{name: "Bât B"})

      assert {:residence, returned_residence, buildings} =
               Residences.verify_code(residence.join_code)

      assert returned_residence.id == residence.id

      returned_ids = Enum.map(buildings, & &1.id) |> Enum.sort()
      expected_ids = Enum.sort([b1.id, b2.id])
      assert returned_ids == expected_ids
    end

    test "reconnaît un code bâtiment et retourne la résidence parent" do
      residence = insert_residence!()
      building = insert_building!(residence)

      assert {:building, returned_building, returned_residence} =
               Residences.verify_code(building.join_code)

      assert returned_building.id == building.id
      assert returned_residence.id == residence.id
    end

    test "retourne :not_found pour un code inconnu" do
      assert :not_found = Residences.verify_code("NEVEREXI")
    end

    test "insensible à la casse et aux espaces" do
      residence = insert_residence!()

      assert {:residence, _, _} =
               Residences.verify_code("  #{String.downcase(residence.join_code)}  ")
    end

    test "ignore les résidences inactives" do
      residence = insert_residence!()
      residence |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      assert :not_found = Residences.verify_code(residence.join_code)
    end
  end

  describe "list_user_residences/1" do
    test "remonte chaque résidence une seule fois même si l'user est dans 2 bâtiments" do
      # Setup: un user, 2 bâtiments dans la même résidence
      {:ok, user} =
        KomunBackend.Accounts.get_or_create_user(
          "test-#{System.unique_integer([:positive])}@komun.app"
        )

      residence = insert_residence!()
      b1 = insert_building!(residence, %{name: "Bât A"})
      b2 = insert_building!(residence, %{name: "Bât B"})

      {:ok, _} = Buildings.add_member(b1.id, user.id, :coproprietaire)
      {:ok, _} = Buildings.add_member(b2.id, user.id, :coproprietaire)

      residences = Residences.list_user_residences(user.id)

      assert length(residences) == 1
      assert hd(residences).id == residence.id
    end
  end

  describe "attach_building/2" do
    test "déplace un bâtiment d'une résidence à une autre" do
      r1 = insert_residence!(%{name: "Source"})
      r2 = insert_residence!(%{name: "Cible"})
      b = insert_building!(r1)

      assert {:ok, updated} = Residences.attach_building(r2.id, b.id)
      assert updated.residence_id == r2.id

      refreshed = Repo.get!(Building, b.id)
      assert refreshed.residence_id == r2.id
    end
  end
end
