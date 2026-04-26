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

    # Depuis l'introduction des résidences, chaque bâtiment doit avoir
    # une `residence_id`. On en crée une dédiée par fixture.
    residence_code =
      "R" <>
        (System.unique_integer([:positive])
         |> Integer.to_string()
         |> String.pad_leading(7, "0"))

    {:ok, residence} =
      %KomunBackend.Residences.Residence{}
      |> KomunBackend.Residences.Residence.changeset(%{
        name: "Résidence #{code}",
        join_code: residence_code
      })
      |> Repo.insert()

    %Building{}
    |> Building.changeset(%{
      name: "La Garenne",
      address: "3 place du Marché",
      city: "Lyon",
      postal_code: "69001",
      organization_id: org.id,
      residence_id: residence.id,
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

      {:ok, %{token: token}} =
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
      {:ok, %{token: token}} = Accounts.create_magic_link("plain@example.com")

      body =
        conn
        |> get(~p"/api/v1/auth/magic-link/verify?token=#{token}")
        |> json_response(200)

      assert body["joined_building"] == nil
    end

    test "returns joined_building: null when join_code doesn't match any building",
         %{conn: conn} do
      {:ok, %{token: token}} = Accounts.create_magic_link("badcode@example.com", join_code: "NOMATCH9")

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

  describe "POST /api/v1/auth/magic-code/verify" do
    test "valid email + code returns access_token, refresh_token, user", %{conn: conn} do
      {:ok, %{code: code}} = Accounts.create_magic_link("ios@example.com")

      body =
        conn
        |> post(~p"/api/v1/auth/magic-code/verify", %{"email" => "ios@example.com", "code" => code})
        |> json_response(200)

      assert body["access_token"]
      assert body["refresh_token"]
      assert body["user"]["email"] == "ios@example.com"
    end

    test "tolerates spaces and dashes in the code (iOS auto-formatting)", %{conn: conn} do
      {:ok, %{code: code}} = Accounts.create_magic_link("space@example.com")
      pretty = String.slice(code, 0, 3) <> " " <> String.slice(code, 3, 3)

      body =
        conn
        |> post(~p"/api/v1/auth/magic-code/verify", %{
          "email" => "space@example.com",
          "code" => pretty
        })
        |> json_response(200)

      assert body["user"]["email"] == "space@example.com"
    end

    test "wrong code → 401 + error message", %{conn: conn} do
      {:ok, _} = Accounts.create_magic_link("bad@example.com")

      conn =
        post(conn, ~p"/api/v1/auth/magic-code/verify", %{
          "email" => "bad@example.com",
          "code" => "000000"
        })

      assert json_response(conn, 401)["error"] =~ "invalide"
    end

    test "5 wrong attempts grills the link (anti brute-force)", %{conn: conn} do
      {:ok, %{code: real}} = Accounts.create_magic_link("brute@example.com")

      # 5 mauvais essais
      for _ <- 1..5 do
        post(conn, ~p"/api/v1/auth/magic-code/verify", %{
          "email" => "brute@example.com",
          "code" => "000000"
        })
      end

      # Le bon code lui-même ne marche plus.
      conn2 =
        post(conn, ~p"/api/v1/auth/magic-code/verify", %{
          "email" => "brute@example.com",
          "code" => real
        })

      assert json_response(conn2, 401)["error"]
    end

    test "missing email or code → 400", %{conn: conn} do
      assert json_response(post(conn, ~p"/api/v1/auth/magic-code/verify", %{}), 400)
    end
  end
end
