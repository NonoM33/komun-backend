defmodule KomunBackendWeb.ArticleControllerTest do
  @moduledoc """
  Tests des endpoints `/api/v1/buildings/:bid/articles`. Couvre :
  - création / édition réservées au CS + syndic
  - lecture des `:published` ouverte aux résidents
  - les brouillons / en relecture sont invisibles aux non-éditeurs
  - la transition vers `:published` pose `published_at`
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

  defp setup_with_member do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)
    {building, user}
  end

  describe "POST /api/v1/buildings/:bid/articles" do
    test "le CS peut créer un brouillon", %{conn: conn} do
      {building, president} = setup_with_president()

      conn =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/articles", %{
          "title" => "Réunion CS du 15 mai",
          "content" => "<p>Ordre du jour…</p>",
          "category" => "vie_copro"
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Réunion CS du 15 mai"
      assert data["status"] == "draft"
      assert data["published_at"] == nil
    end

    test "un copropriétaire lambda reçoit 403", %{conn: conn} do
      {building, member} = setup_with_member()

      conn =
        conn
        |> authed(member)
        |> post(~p"/api/v1/buildings/#{building.id}/articles", %{
          "title" => "Tentative",
          "content" => ""
        })

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/v1/buildings/:bid/articles" do
    test "un voisin lambda ne voit que les articles publiés", %{conn: conn} do
      {building, president} = setup_with_president()
      member = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, member.id, :coproprietaire)

      # Création d'un brouillon par le CS
      _conn1 =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/articles", %{
          "title" => "Brouillon visible que par CS",
          "content" => "secret"
        })

      # Création + publication d'un second article
      created =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/articles", %{
          "title" => "Publié pour tous",
          "content" => "hello"
        })
        |> json_response(201)

      published_id = created["data"]["id"]

      _ =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/articles/#{published_id}/transition", %{
          "status" => "published"
        })
        |> json_response(200)

      # Vue voisin lambda
      list_conn =
        conn
        |> authed(member)
        |> get(~p"/api/v1/buildings/#{building.id}/articles")

      assert %{"data" => articles} = json_response(list_conn, 200)
      assert length(articles) == 1
      assert hd(articles)["title"] == "Publié pour tous"
      assert hd(articles)["status"] == "published"
    end

    test "le CS voit tous les statuts via ?status=all", %{conn: conn} do
      {building, president} = setup_with_president()

      conn
      |> authed(president)
      |> post(~p"/api/v1/buildings/#{building.id}/articles", %{
        "title" => "Brouillon 1",
        "content" => ""
      })
      |> json_response(201)

      list =
        conn
        |> authed(president)
        |> get(~p"/api/v1/buildings/#{building.id}/articles?status=all")
        |> json_response(200)

      assert %{"data" => [%{"title" => "Brouillon 1", "status" => "draft"}]} = list
    end
  end

  describe "POST /api/v1/buildings/:bid/articles/:id/transition" do
    test "publier pose published_at", %{conn: conn} do
      {building, president} = setup_with_president()

      created =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/articles", %{
          "title" => "À publier",
          "content" => "ok"
        })
        |> json_response(201)

      id = created["data"]["id"]

      published =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/articles/#{id}/transition", %{
          "status" => "published"
        })
        |> json_response(200)

      assert published["data"]["status"] == "published"
      assert is_binary(published["data"]["published_at"])
    end

    test "un voisin lambda reçoit 403 sur transition", %{conn: conn} do
      {building, president} = setup_with_president()
      member = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, member.id, :coproprietaire)

      created =
        conn
        |> authed(president)
        |> post(~p"/api/v1/buildings/#{building.id}/articles", %{
          "title" => "À publier",
          "content" => "ok"
        })
        |> json_response(201)

      id = created["data"]["id"]

      conn =
        conn
        |> authed(member)
        |> post(~p"/api/v1/buildings/#{building.id}/articles/#{id}/transition", %{
          "status" => "published"
        })

      assert json_response(conn, 403)
    end
  end
end
