defmodule KomunBackendWeb.BuildingControllerTest do
  @moduledoc """
  Tests des endpoints `/api/v1/buildings`. Aujourd'hui couvre surtout
  la non-régression du champ `residence_id` dans la sérialisation —
  le frontend en a besoin pour les pages résidence-scope (RSS, etc.).
  Sans ce champ, la page « Actu locale » bloque sur "Aucune résidence
  rattachée à votre compte".
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.{Buildings, Repo, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Residences.Residence

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

  defp insert_building!(residence) do
    %Building{}
    |> Building.initial_changeset(%{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "2 rue des Lilas",
      city: "Paris",
      postal_code: "75015",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    })
    |> Repo.insert!()
  end

  defp insert_user!(role \\ :coproprietaire) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp authed(conn, user) do
    {:ok, token, _claims} = Guardian.sign_in(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /api/v1/buildings" do
    test "expose residence_id pour chaque bâtiment de l'utilisateur", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)

      body =
        conn
        |> authed(user)
        |> get(~p"/api/v1/buildings")
        |> json_response(200)

      assert [item] = body["data"]
      assert item["id"] == building.id
      assert item["residence_id"] == residence.id
    end
  end

  describe "GET /api/v1/buildings/:id" do
    test "expose residence_id sur la fiche", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)

      body =
        conn
        |> authed(user)
        |> get(~p"/api/v1/buildings/#{building.id}")
        |> json_response(200)

      assert body["data"]["id"] == building.id
      assert body["data"]["residence_id"] == residence.id
    end

    test "membre → succès", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)

      body =
        conn
        |> authed(user)
        |> get(~p"/api/v1/buildings/#{building.id}")
        |> json_response(200)

      assert body["data"]["id"] == building.id
    end

    test "authentifié non-membre → 403 (n'expose pas l'adresse d'un bâtiment tiers)",
         %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      # Utilisateur authentifié mais rattaché à AUCUN bâtiment.
      outsider = insert_user!()

      conn
      |> authed(outsider)
      |> get(~p"/api/v1/buildings/#{building.id}")
      |> json_response(403)
    end
  end

  describe "GET /api/v1/buildings/:id/members" do
    test "membre → succès", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)

      body =
        conn
        |> authed(user)
        |> get(~p"/api/v1/buildings/#{building.id}/members")
        |> json_response(200)

      assert is_list(body["data"])
    end

    test "authentifié non-membre → 403 (n'expose pas emails/noms des membres)",
         %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      member = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, member.id, :coproprietaire)
      outsider = insert_user!()

      conn
      |> authed(outsider)
      |> get(~p"/api/v1/buildings/#{building.id}/members")
      |> json_response(403)
    end
  end

  describe "GET /api/v1/buildings/:id/lots" do
    test "membre → succès", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)

      body =
        conn
        |> authed(user)
        |> get(~p"/api/v1/buildings/#{building.id}/lots")
        |> json_response(200)

      assert is_list(body["data"])
    end

    test "authentifié non-membre → 403 (n'expose pas la cartographie des lots)",
         %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      outsider = insert_user!()

      conn
      |> authed(outsider)
      |> get(~p"/api/v1/buildings/#{building.id}/lots")
      |> json_response(403)
    end
  end

  describe "DELETE /api/v1/buildings/:id" do
    test "président CS DU bâtiment → passe l'authz (403 seulement si non-membre)",
         %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      president = insert_user!(:president_cs)
      {:ok, _} = Buildings.add_member(building.id, president.id, :president_cs)

      body =
        conn
        |> authed(president)
        |> delete(~p"/api/v1/buildings/#{building.id}")
        |> json_response(422)

      # 422 (et non 403) prouve que le président CS DU bâtiment a franchi
      # l'authz : le refus est purement métier (il reste un membre actif).
      assert body["error"] == "has_active_members"
    end

    test "CS d'un AUTRE bâtiment → 403 (ne peut pas supprimer un bâtiment tiers)",
         %{conn: conn} do
      residence = insert_residence!()
      building_a = insert_building!(residence)
      building_b = insert_building!(residence)

      # Président CS du bâtiment A uniquement.
      president_a = insert_user!(:president_cs)
      {:ok, _} = Buildings.add_member(building_a.id, president_a.id, :president_cs)

      conn
      |> authed(president_a)
      |> delete(~p"/api/v1/buildings/#{building_b.id}")
      |> json_response(403)
    end

    test "authentifié non-membre (rôle global copropriétaire) → 403", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      outsider = insert_user!(:coproprietaire)

      conn
      |> authed(outsider)
      |> delete(~p"/api/v1/buildings/#{building.id}")
      |> json_response(403)
    end
  end
end
