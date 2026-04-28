defmodule KomunBackendWeb.FloorMapControllerTest do
  @moduledoc """
  Tests des endpoints `/api/v1/buildings/:b/floor-map`,
  `/api/v1/lots/:id/adjacency` et `/api/v1/lots/:id/notify-preview`.

  Sécurité :
  - Lecture (`GET /floor-map`, `GET /notify-preview`) : super_admin,
    syndic_*, président/membre CS.
  - Édition (`PATCH /lots/:id/adjacency`) : super_admin, syndic_manager
    uniquement (le CS ne peut PAS éditer la cartographie officielle).
  - Tout autre rôle → 403.
  """

  use KomunBackendWeb.ConnCase, async: false

  import Ecto.Query

  alias KomunBackend.{Buildings, Repo, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.{Building, Lot}
  alias KomunBackend.Residences.Residence

  defp insert_residence! do
    {:ok, r} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: "Rés #{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> Repo.insert()

    r
  end

  defp insert_building!(residence) do
    %Building{}
    |> Building.initial_changeset(%{
      name: "B #{System.unique_integer([:positive])}",
      address: "1 rue Test",
      city: "Paris",
      postal_code: "75001",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    })
    |> Repo.insert!()
  end

  defp insert_lot!(building, attrs) do
    %Lot{}
    |> Lot.changeset(Map.merge(%{type: :apartment, building_id: building.id}, attrs))
    |> Repo.insert!()
  end

  defp insert_user!(role \\ :coproprietaire) do
    %User{}
    |> User.changeset(%{
      email: "u#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp authed(conn, user) do
    {:ok, token, _} = Guardian.sign_in(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp link_member!(building_id, user, lot, role \\ :coproprietaire) do
    {:ok, m} = Buildings.add_member(building_id, user.id, role)
    m |> Ecto.Changeset.change(primary_lot_id: lot.id) |> Repo.update!()
  end

  describe "GET /buildings/:b/floor-map" do
    test "renvoie les lots groupés par étage avec adjacence calculée pour le syndic",
         %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)

      _lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      _lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})
      _lot_2002 = insert_lot!(b, %{number: "2002", floor: 2})

      syndic = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(b.id, syndic.id, :coproprietaire)

      body =
        conn
        |> authed(syndic)
        |> get(~p"/api/v1/buildings/#{b.id}/floor-map")
        |> json_response(200)

      assert [%{"floor" => 2}, %{"floor" => 1}] = body["data"]

      [floor2, floor1] = body["data"]
      assert length(floor2["lots"]) == 2
      assert length(floor1["lots"]) == 1

      lot_2003 = Enum.find(floor2["lots"], &(&1["number"] == "2003"))
      assert lot_2003["computed_below"]["number"] == "1003"
    end

    test "403 pour un copropriétaire standard", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, user.id, :coproprietaire)

      assert conn
             |> authed(user)
             |> get(~p"/api/v1/buildings/#{b.id}/floor-map")
             |> json_response(403)
    end

    test "200 pour un membre du CS (lecture seule)", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      _lot = insert_lot!(b, %{number: "1001", floor: 1})

      user = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, user.id, :membre_cs)

      assert conn
             |> authed(user)
             |> get(~p"/api/v1/buildings/#{b.id}/floor-map")
             |> json_response(200)
    end
  end

  describe "PATCH /lots/:id/adjacency" do
    test "le syndic peut overrider unit_below_lot_id", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      lot_1002 = insert_lot!(b, %{number: "1002", floor: 1})

      syndic = insert_user!(:syndic_manager)

      body =
        conn
        |> authed(syndic)
        |> patch(~p"/api/v1/lots/#{lot_2003.id}/adjacency", %{
          unit_below_lot_id: lot_1002.id
        })
        |> json_response(200)

      assert body["data"]["override_below_id"] == lot_1002.id

      assert Repo.get(Lot, lot_2003.id).unit_below_lot_id == lot_1002.id
    end

    test "rejette un override où le lot se pointe lui-même", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      lot = insert_lot!(b, %{number: "2003", floor: 2})

      syndic = insert_user!(:syndic_manager)

      body =
        conn
        |> authed(syndic)
        |> patch(~p"/api/v1/lots/#{lot.id}/adjacency", %{unit_below_lot_id: lot.id})
        |> json_response(422)

      assert body["errors"]["unit_below_lot_id"]
    end

    test "403 pour un président_cs (édition réservée syndic)", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      lot = insert_lot!(b, %{number: "2003", floor: 2})

      pres = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, pres.id, :president_cs)

      assert conn
             |> authed(pres)
             |> patch(~p"/api/v1/lots/#{lot.id}/adjacency", %{unit_below_lot_id: nil})
             |> json_response(403)
    end

    test "403 pour un copropriétaire", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      lot = insert_lot!(b, %{number: "2003", floor: 2})

      copro = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, copro.id, :coproprietaire)

      assert conn
             |> authed(copro)
             |> patch(~p"/api/v1/lots/#{lot.id}/adjacency", %{unit_below_lot_id: nil})
             |> json_response(403)
    end
  end

  describe "GET /lots/:id/notify-preview" do
    test "preview water_leak montre le membre du logement en dessous", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})

      target_user = insert_user!()
      link_member!(b.id, target_user, lot_1003)

      syndic = insert_user!(:syndic_manager)

      body =
        conn
        |> authed(syndic)
        |> get(~p"/api/v1/lots/#{lot_2003.id}/notify-preview?subtype=water_leak")
        |> json_response(200)

      assert body["data"]["subtype"] == "water_leak"
      assert [target] = body["data"]["targets"]
      assert target["lot"]["number"] == "1003"
      assert [member] = target["members"]
      assert member["id"] == target_user.id
    end

    test "preview noise montre les voisins de palier", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2001 = insert_lot!(b, %{number: "2001", floor: 2})
      lot_2002 = insert_lot!(b, %{number: "2002", floor: 2})

      neighbor = insert_user!()
      link_member!(b.id, neighbor, lot_2002)

      syndic = insert_user!(:syndic_manager)

      body =
        conn
        |> authed(syndic)
        |> get(~p"/api/v1/lots/#{lot_2001.id}/notify-preview?subtype=noise")
        |> json_response(200)

      assert body["data"]["subtype"] == "noise"
      assert [target] = body["data"]["targets"]
      assert target["lot"]["number"] == "2002"
    end
  end

  describe "POST /buildings/:b/lots/generate" do
    test "le syndic amorce les lots avec la convention de numérotation",
         %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      syndic = insert_user!(:syndic_manager)

      body =
        conn
        |> authed(syndic)
        |> post(~p"/api/v1/buildings/#{b.id}/lots/generate", %{
          floors: 2,
          lots_per_floor: 3
        })
        |> json_response(200)

      # La réponse rejoue /floor-map (groupes par étage, ordre desc).
      assert [%{"floor" => 2, "lots" => f2}, %{"floor" => 1, "lots" => f1}] =
               body["data"]

      numbers_f2 = f2 |> Enum.map(& &1["number"]) |> Enum.sort()
      numbers_f1 = f1 |> Enum.map(& &1["number"]) |> Enum.sort()
      assert numbers_f2 == ["2001", "2002", "2003"]
      assert numbers_f1 == ["1001", "1002", "1003"]

      # La convention 2003 → 1003 doit fonctionner immédiatement.
      lot_2003 = Enum.find(f2, &(&1["number"] == "2003"))
      assert lot_2003["computed_below"]["number"] == "1003"
    end

    test "409 si le bâtiment a déjà des lots", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      _existing = insert_lot!(b, %{number: "1001", floor: 1})

      syndic = insert_user!(:syndic_manager)

      assert conn
             |> authed(syndic)
             |> post(~p"/api/v1/buildings/#{b.id}/lots/generate", %{
               floors: 2,
               lots_per_floor: 3
             })
             |> json_response(409)

      # Aucun lot supplémentaire n'est créé.
      assert Repo.aggregate(
               from(l in Lot, where: l.building_id == ^b.id),
               :count
             ) == 1
    end

    test "422 si floors ou lots_per_floor < 1", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      syndic = insert_user!(:syndic_manager)

      assert conn
             |> authed(syndic)
             |> post(~p"/api/v1/buildings/#{b.id}/lots/generate", %{
               floors: 0,
               lots_per_floor: 3
             })
             |> json_response(422)

      assert conn
             |> authed(syndic)
             |> post(~p"/api/v1/buildings/#{b.id}/lots/generate", %{
               floors: 2,
               lots_per_floor: 0
             })
             |> json_response(422)

      assert Repo.aggregate(
               from(l in Lot, where: l.building_id == ^b.id),
               :count
             ) == 0
    end

    test "403 pour un membre du CS (lecture seule)", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, user.id, :membre_cs)

      assert conn
             |> authed(user)
             |> post(~p"/api/v1/buildings/#{b.id}/lots/generate", %{
               floors: 2,
               lots_per_floor: 3
             })
             |> json_response(403)
    end
  end

  describe "DELETE /lots/:id" do
    test "le syndic supprime un lot et la réponse rejoue /floor-map sans lui",
         %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      lot_1001 = insert_lot!(b, %{number: "1001", floor: 1})
      _lot_1002 = insert_lot!(b, %{number: "1002", floor: 1})

      syndic = insert_user!(:syndic_manager)

      body =
        conn
        |> authed(syndic)
        |> delete(~p"/api/v1/lots/#{lot_1001.id}")
        |> json_response(200)

      assert [%{"floor" => 1, "lots" => f1}] = body["data"]
      numbers = f1 |> Enum.map(& &1["number"]) |> Enum.sort()
      assert numbers == ["1002"]

      refute Repo.get(Lot, lot_1001.id)
    end

    test "nettoie les neighbor_lot_ids des autres lots qui pointaient vers lui",
         %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      lot_a = insert_lot!(b, %{number: "1001", floor: 1})
      lot_b = insert_lot!(b, %{number: "1002", floor: 1})
      lot_c = insert_lot!(b, %{number: "1003", floor: 1})

      lot_b
      |> Ecto.Changeset.change(neighbor_lot_ids: [lot_a.id, lot_c.id])
      |> Repo.update!()

      syndic = insert_user!(:syndic_manager)

      conn
      |> authed(syndic)
      |> delete(~p"/api/v1/lots/#{lot_a.id}")
      |> json_response(200)

      assert Repo.get(Lot, lot_b.id).neighbor_lot_ids == [lot_c.id]
    end

    test "nilify les overrides d'adjacence des lots qui pointaient vers lui",
         %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      lot_below = insert_lot!(b, %{number: "1001", floor: 1})
      lot_above = insert_lot!(b, %{number: "2001", floor: 2})

      lot_above
      |> Ecto.Changeset.change(unit_below_lot_id: lot_below.id)
      |> Repo.update!()

      syndic = insert_user!(:syndic_manager)

      conn
      |> authed(syndic)
      |> delete(~p"/api/v1/lots/#{lot_below.id}")
      |> json_response(200)

      refute Repo.get(Lot, lot_above.id).unit_below_lot_id
    end

    test "détache (nilify) le primary_lot des membres rattachés à ce lot",
         %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      lot = insert_lot!(b, %{number: "1001", floor: 1})

      user = insert_user!()
      member = link_member!(b.id, user, lot)

      syndic = insert_user!(:syndic_manager)

      conn
      |> authed(syndic)
      |> delete(~p"/api/v1/lots/#{lot.id}")
      |> json_response(200)

      refute Repo.reload!(member).primary_lot_id
    end

    test "403 pour un membre du CS (édition réservée au syndic)", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      lot = insert_lot!(b, %{number: "1001", floor: 1})
      user = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, user.id, :membre_cs)

      assert conn
             |> authed(user)
             |> delete(~p"/api/v1/lots/#{lot.id}")
             |> json_response(403)

      assert Repo.get(Lot, lot.id)
    end
  end
end
