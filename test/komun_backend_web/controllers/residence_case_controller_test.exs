defmodule KomunBackendWeb.ResidenceCaseControllerTest do
  @moduledoc """
  Couvre les endpoints `POST /api/v1/residences/:rid/{incidents,
  doleances, diligences}` qui créent un dossier rattaché à la résidence
  entière. Le focus est l'**authorization** :

    * incident / doléance : tout user membre d'au moins un bâtiment de
      la résidence est autorisé.
    * diligence : seuls les rôles privilégiés (syndic / CS / super_admin).
    * Tous : 403 si l'utilisateur n'est membre d'aucun bâtiment de la
      résidence et n'est pas super_admin global.

  On vérifie aussi que le dossier créé est ensuite visible dans le GET
  building-scoped (les listes par bâtiment incluent les sujets résidence).
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
      address: "1 rue Test",
      city: "Paris",
      postal_code: "75001",
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

  defp setup_residence_with_two_buildings_and_member(member_role \\ :coproprietaire) do
    residence = insert_residence!()
    building_a = insert_building!(residence)
    building_b = insert_building!(residence)
    user = insert_user!()
    {:ok, _} = Buildings.add_member(building_a.id, user.id, member_role)
    {residence, building_a, building_b, user}
  end

  describe "POST /api/v1/residences/:rid/incidents" do
    test "crée un incident résidence-scoped (copropriétaire d'un des bâtiments)", %{conn: conn} do
      {residence, _ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/incidents", %{
          "incident" => %{
            "title" => "Vice de construction commun aux deux bâtiments",
            "description" => "Fissures sur les façades extérieures partagées",
            "category" => "facades",
            "severity" => "high",
            "status" => "brouillon"
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] =~ "Vice de construction"
      assert data["residence_id"] == residence.id
      assert is_nil(data["building_id"])
    end

    test "renvoie 403 si user n'est membre d'aucun bâtiment de la résidence", %{conn: conn} do
      residence = insert_residence!()
      _ = insert_building!(residence)
      stranger = insert_user!()

      conn =
        conn
        |> authed(stranger)
        |> post(~p"/api/v1/residences/#{residence.id}/incidents", %{
          "incident" => %{
            "title" => "Tentative",
            "description" => "Pas autorisé",
            "category" => "autre"
          }
        })

      assert json_response(conn, 403)
    end

    test "le dossier résidence apparaît dans le GET /buildings/:bid/incidents", %{conn: conn} do
      {residence, ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      _ =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/incidents", %{
          "incident" => %{
            "title" => "Sujet partagé entre bâtiments",
            "description" => "Concerne tous les copropriétaires",
            "category" => "parties_communes"
          }
        })
        |> json_response(201)

      # Liste vue depuis le bâtiment A — doit inclure le résidence-scoped
      conn =
        conn
        |> authed(user)
        |> get(~p"/api/v1/buildings/#{ba.id}/incidents")

      body = json_response(conn, 200)
      titles = body["data"] |> Enum.map(& &1["title"])
      assert "Sujet partagé entre bâtiments" in titles
    end
  end

  describe "POST /api/v1/residences/:rid/doleances" do
    test "crée une doléance résidence-scoped", %{conn: conn} do
      {residence, _ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/doleances", %{
          "doleance" => %{
            "title" => "Voirie commune dégradée",
            "description" => "Les allées de la résidence sont défoncées",
            "category" => "voirie_parking"
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["residence_id"] == residence.id
      assert is_nil(data["building_id"])
    end

    test "renvoie 403 à un non-membre", %{conn: conn} do
      residence = insert_residence!()
      _ = insert_building!(residence)
      stranger = insert_user!()

      conn =
        conn
        |> authed(stranger)
        |> post(~p"/api/v1/residences/#{residence.id}/doleances", %{
          "doleance" => %{
            "title" => "X",
            "description" => "Pas autorisé",
            "category" => "autre"
          }
        })

      assert json_response(conn, 403)
    end
  end

  describe "POST /api/v1/residences/:rid/diligences" do
    test "crée une diligence résidence-scoped pour un président_cs", %{conn: conn} do
      {residence, _ba, _bb, user} =
        setup_residence_with_two_buildings_and_member(:president_cs)

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/diligences", %{
          "diligence" => %{
            "title" => "Procédure trouble anormal — résidence",
            "description" => "Sujet transverse à toute la résidence",
            "source_type" => "copro_owner"
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["residence_id"] == residence.id
      assert is_nil(data["building_id"])
    end

    test "renvoie 403 à un copropriétaire standard (diligence = privilégiés only)", %{conn: conn} do
      {residence, _ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/diligences", %{
          "diligence" => %{"title" => "Tentative interdite"}
        })

      assert json_response(conn, 403)
    end

    test "autorise un super_admin global même non-membre", %{conn: conn} do
      residence = insert_residence!()
      _ = insert_building!(residence)
      admin = insert_user!(:super_admin)

      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/v1/residences/#{residence.id}/diligences", %{
          "diligence" => %{
            "title" => "Procédure résidence par super_admin",
            "description" => "Test",
            "source_type" => "unknown"
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["residence_id"] == residence.id
    end
  end

  describe "résidence inexistante" do
    test "renvoie 404 sur les 3 endpoints", %{conn: conn} do
      user = insert_user!()
      fake_id = Ecto.UUID.generate()

      for path <- [
            ~p"/api/v1/residences/#{fake_id}/incidents",
            ~p"/api/v1/residences/#{fake_id}/doleances",
            ~p"/api/v1/residences/#{fake_id}/diligences"
          ] do
        conn = conn |> authed(user) |> post(path, %{})
        assert json_response(conn, 404)
      end
    end
  end
end
