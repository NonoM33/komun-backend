defmodule KomunBackendWeb.AuthMagicLinkSignupTest do
  use KomunBackendWeb.ConnCase

  alias KomunBackend.Repo
  alias KomunBackend.Accounts
  alias KomunBackend.Accounts.{MagicLink, User}
  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Organizations.Organization

  defp insert_building!(code) do
    {:ok, org} =
      %Organization{}
      |> Organization.changeset(%{name: "Org #{System.unique_integer([:positive])}"})
      |> Repo.insert()

    %Building{}
    |> Building.changeset(%{
      name: "La Garenne",
      address: "3 place du Marché",
      city: "Lyon",
      postal_code: "69001",
      organization_id: org.id,
      join_code: code
    })
    |> Repo.insert!()
  end

  describe "POST /api/v1/auth/magic-link" do
    test "stores first_name / last_name / join_code alongside the link", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/magic-link", %{
          "email" => "newuser@example.com",
          "first_name" => "Alice",
          "last_name" => "Martin",
          "join_code" => "ABC12345"
        })

      assert json_response(conn, 200)["message"] =~ "newuser@example.com"

      ml = Repo.get_by(MagicLink, email: "newuser@example.com")
      assert ml.first_name == "Alice"
      assert ml.last_name == "Martin"
      assert ml.join_code == "ABC12345"
    end

    test "accepts the plain {email} payload (no signup fields)", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/auth/magic-link", %{"email" => "plain@example.com"})
      assert json_response(conn, 200)

      ml = Repo.get_by(MagicLink, email: "plain@example.com")
      assert is_nil(ml.first_name)
      assert is_nil(ml.last_name)
      assert is_nil(ml.join_code)
    end

    test "rejects request without an email", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/auth/magic-link", %{})
      assert json_response(conn, 400)["error"] =~ "email"
    end
  end

  describe "GET /api/v1/auth/magic-link/verify" do
    test "returns tokens, user, and joined_building when the link carries a join_code",
         %{conn: conn} do
      building = insert_building!("MAGICJN1")

      {:ok, token} =
        Accounts.create_magic_link("joiner@example.com",
          first_name: "Jean",
          last_name: "Dupont",
          join_code: "MAGICJN1"
        )

      conn = get(conn, ~p"/api/v1/auth/magic-link/verify?token=#{token}")
      body = json_response(conn, 200)

      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      assert body["user"]["email"] == "joiner@example.com"
      assert body["user"]["first_name"] == "Jean"
      assert body["user"]["last_name"] == "Dupont"
      assert body["joined_building"]["id"] == building.id
      assert body["joined_building"]["name"] == "La Garenne"

      # Sanity: membership really exists in the DB.
      user = Repo.get_by(User, email: "joiner@example.com")
      assert Buildings.member?(building.id, user.id)
    end

    test "returns joined_building: null when the link has no join_code", %{conn: conn} do
      {:ok, token} = Accounts.create_magic_link("plain@example.com")

      body =
        conn
        |> get(~p"/api/v1/auth/magic-link/verify?token=#{token}")
        |> json_response(200)

      assert body["joined_building"] == nil
    end

    test "returns joined_building: null when join_code doesn't match any building",
         %{conn: conn} do
      {:ok, token} = Accounts.create_magic_link("badcode@example.com", join_code: "NOMATCH9")

      body =
        conn
        |> get(~p"/api/v1/auth/magic-link/verify?token=#{token}")
        |> json_response(200)

      assert body["joined_building"] == nil
      assert body["user"]["email"] == "badcode@example.com"
    end

    test "401s on invalid token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/auth/magic-link/verify?token=not-a-real-token")
      assert json_response(conn, 401)["error"] =~ "Invalid"
    end
  end
end
