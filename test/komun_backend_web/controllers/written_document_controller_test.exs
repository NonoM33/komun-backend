defmodule KomunBackendWeb.WrittenDocumentControllerTest do
  @moduledoc """
  Tests des endpoints `/api/v1/buildings/:bid/written_documents`.
  Symétriques aux ArticleControllerTest — on couvre surtout la
  matrice d'autorisation puisque la logique métier est identique.
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

  defp setup_with_president do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, user.id, :president_cs)
    {building, user}
  end

  describe "POST /api/v1/buildings/:bid/written_documents" do
    test "le CS peut rédiger un PV en brouillon", %{conn: conn} do
      {building, president} = setup_with_president()

      conn =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/written_documents", %{
          "title" => "PV Conseil syndical du 12 mars",
          "content" => "<h2>Présents</h2><p>…</p>",
          "category" => "pv_conseil"
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "PV Conseil syndical du 12 mars"
      assert data["status"] == "draft"
      assert data["category"] == "pv_conseil"
    end

    test "un voisin lambda reçoit 403", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      member = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, member.id, :coproprietaire)

      conn =
        conn
        |> authed(member)
        |> post(~p"/api/v1/buildings/#{building.id}/written_documents", %{
          "title" => "Tentative",
          "content" => ""
        })

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/v1/buildings/:bid/written_documents" do
    test "un voisin lambda ne voit que les PV publiés", %{conn: conn} do
      {building, president} = setup_with_president()
      member = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, member.id, :coproprietaire)

      # Brouillon (invisible aux voisins)
      _ =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/written_documents", %{
          "title" => "Brouillon CS",
          "content" => ""
        })
        |> json_response(201)

      # Publié
      created =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/written_documents", %{
          "title" => "PV publié",
          "content" => ""
        })
        |> json_response(201)

      _ =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/written_documents/#{created["data"]["id"]}/transition",
          %{"status" => "published"}
        )
        |> json_response(200)

      list =
        conn
        |> authed(member)
        |> get(~p"/api/v1/buildings/#{building.id}/written_documents")
        |> json_response(200)

      assert %{"data" => [doc]} = list
      assert doc["title"] == "PV publié"
    end
  end

  describe "POST /api/v1/buildings/:bid/written_documents/:id/archive" do
    test "le CS peut archiver un PV", %{conn: conn} do
      {building, president} = setup_with_president()

      created =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/written_documents", %{
          "title" => "À archiver",
          "content" => ""
        })
        |> json_response(201)

      archived =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/written_documents/#{created["data"]["id"]}/archive")
        |> json_response(200)

      assert archived["data"]["is_archived"] == true
      assert is_binary(archived["data"]["archived_at"])
    end
  end
end
