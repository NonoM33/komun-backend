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
  end
end
