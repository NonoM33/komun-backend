defmodule KomunBackendWeb.ResidenceControllerTest do
  @moduledoc """
  Tests publics de `GET /api/v1/codes/verify` — couvre le cas typique
  d'un code résidence multi-bâtiments avec un placeholder résiduel
  (artefact de l'ancien flow `Buildings.create_building/1` qui auto-
  créait une résidence du même nom). Le placeholder doit disparaître
  du payload pour que l'utilisateur ne voie pas « unissons » dans le
  dropdown bâtiment, à côté de « Bâtiment A » et « Bâtiment B ».
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.{Buildings, Repo, Residences}
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Residences.Residence

  defp insert_residence!(name \\ nil) do
    {:ok, r} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: name || "Résidence #{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> Repo.insert()

    r
  end

  defp insert_building!(residence, attrs) do
    base = %{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "2 rue des Lilas",
      city: "Paris",
      postal_code: "75015",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    }

    %Building{}
    |> Building.initial_changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  describe "GET /api/v1/codes/verify (code résidence)" do
    test "cache les bâtiments-placeholder du payload buildings", %{conn: conn} do
      residence = insert_residence!("Unissons")
      _placeholder = insert_building!(residence, %{name: "Unissons", is_placeholder: true})
      real_a = insert_building!(residence, %{name: "Bâtiment A"})
      real_b = insert_building!(residence, %{name: "Bâtiment B"})

      body =
        conn
        |> get(~p"/api/v1/codes/verify?code=#{residence.join_code}")
        |> json_response(200)

      assert body["valid"] == true
      assert body["type"] == "residence"

      returned_ids = body["buildings"] |> Enum.map(& &1["id"]) |> Enum.sort()
      assert returned_ids == Enum.sort([real_a.id, real_b.id])

      returned_names = body["buildings"] |> Enum.map(& &1["name"])
      refute "Unissons" in returned_names
    end

    test "garde le placeholder quand c'est l'unique bâtiment de la résidence", %{conn: conn} do
      # Cas mono-bâtiment : la résidence et son seul bâtiment
      # s'appellent pareil. Si on filtrait, on rendrait une liste vide
      # → le frontend ne saurait sur quoi inscrire l'utilisateur.
      residence = insert_residence!("Solo Copro")
      placeholder = insert_building!(residence, %{name: "Solo Copro", is_placeholder: true})

      body =
        conn
        |> get(~p"/api/v1/codes/verify?code=#{residence.join_code}")
        |> json_response(200)

      assert [item] = body["buildings"]
      assert item["id"] == placeholder.id
      assert item["is_placeholder"] == true
    end

    test "expose is_placeholder sur chaque entrée du payload", %{conn: conn} do
      residence = insert_residence!("Mixed")
      _placeholder = insert_building!(residence, %{name: "Mixed", is_placeholder: true})
      _real = insert_building!(residence, %{name: "Bâtiment Réel"})

      body =
        conn
        |> get(~p"/api/v1/codes/verify?code=#{residence.join_code}")
        |> json_response(200)

      Enum.each(body["buildings"], fn b ->
        assert Map.has_key?(b, "is_placeholder")
      end)
    end
  end

  describe "Buildings.create_building/1 (auto-residence path)" do
    # Mirroir du path controller : les attrs viennent en string keys
    # (params JSON décodés par Plug). `ensure_join_code` et
    # `ensure_residence` partent de cette base.
    test "marque le bâtiment auto-créé comme placeholder" do
      attrs = %{
        "name" => "Mono Building Test",
        "address" => "1 rue Test",
        "city" => "Paris",
        "postal_code" => "75001"
      }

      {:ok, building} = Buildings.create_building(attrs)
      reloaded = Repo.get!(Building, building.id)

      assert reloaded.is_placeholder == true
      assert reloaded.residence_id != nil
    end

    test "ne flag PAS quand residence_id est fourni explicitement" do
      residence = insert_residence!()

      attrs = %{
        "name" => "Bâtiment explicite",
        "address" => "1 rue Test",
        "city" => "Paris",
        "postal_code" => "75001",
        "residence_id" => residence.id
      }

      {:ok, building} = Buildings.create_building(attrs)
      reloaded = Repo.get!(Building, building.id)

      assert reloaded.is_placeholder == false
    end
  end
end
