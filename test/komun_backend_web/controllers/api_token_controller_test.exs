defmodule KomunBackendWeb.ApiTokenControllerTest do
  @moduledoc """
  Tests des endpoints `/api/v1/me/api-tokens` :
  liste / création / révocation, gating par rôle, et bout-à-bout
  de l'auth via `Authorization: Bearer kmn_pat_...`.
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.Repo
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.{ApiTokens, Guardian}

  defp insert_user!(role \\ :membre_cs) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp jwt_for(user) do
    {:ok, token, _} = Guardian.encode_and_sign(user, %{}, ttl: {1, :hour})
    token
  end

  defp with_auth(conn, jwt) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{jwt}")
  end

  describe "POST /api/v1/me/api-tokens" do
    test "un membre du conseil reçoit un token clair une seule fois", %{conn: conn} do
      user = insert_user!(:president_cs)

      conn =
        conn
        |> with_auth(jwt_for(user))
        |> post("/api/v1/me/api-tokens", %{"name" => "Script ChatGPT"})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["name"] == "Script ChatGPT"
      assert String.starts_with?(data["token"], "kmn_pat_")
      assert is_binary(data["token_prefix"])
    end

    test "un copropriétaire ordinaire est refusé", %{conn: conn} do
      user = insert_user!(:coproprietaire)

      conn =
        conn
        |> with_auth(jwt_for(user))
        |> post("/api/v1/me/api-tokens", %{"name" => "x"})

      assert json_response(conn, 403)
    end

    test "le nom est requis", %{conn: conn} do
      user = insert_user!(:membre_cs)

      conn =
        conn
        |> with_auth(jwt_for(user))
        |> post("/api/v1/me/api-tokens", %{})

      assert %{"errors" => %{"name" => _}} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/me/api-tokens" do
    test "liste les tokens du user (sans révéler le clair)", %{conn: conn} do
      user = insert_user!(:membre_cs)
      {:ok, _} = ApiTokens.create_token(user, %{"name" => "T1"})
      {:ok, _} = ApiTokens.create_token(user, %{"name" => "T2"})

      conn =
        conn
        |> with_auth(jwt_for(user))
        |> get("/api/v1/me/api-tokens")

      assert %{"data" => list} = json_response(conn, 200)
      assert length(list) == 2
      refute Enum.any?(list, &Map.has_key?(&1, "token"))
    end
  end

  describe "DELETE /api/v1/me/api-tokens/:id" do
    test "révoque un token de l'utilisateur courant", %{conn: conn} do
      user = insert_user!(:membre_cs)
      {:ok, %{api_token: token}} = ApiTokens.create_token(user, %{"name" => "kill"})

      conn =
        conn
        |> with_auth(jwt_for(user))
        |> delete("/api/v1/me/api-tokens/#{token.id}")

      assert %{"data" => %{"revoked_at" => revoked_at}} = json_response(conn, 200)
      assert is_binary(revoked_at)
    end

    test "n'autorise pas à révoquer le token d'un autre user", %{conn: conn} do
      victim = insert_user!(:membre_cs)
      attacker = insert_user!(:membre_cs)
      {:ok, %{api_token: token}} = ApiTokens.create_token(victim, %{"name" => "victim"})

      conn =
        conn
        |> with_auth(jwt_for(attacker))
        |> delete("/api/v1/me/api-tokens/#{token.id}")

      assert json_response(conn, 404)
    end
  end

  describe "auth via API token (bout-à-bout)" do
    test "GET /me avec un kmn_pat_ valide identifie le user", %{conn: conn} do
      user = insert_user!(:president_cs)
      {:ok, %{plaintext: plaintext}} = ApiTokens.create_token(user, %{"name" => "for /me"})

      conn =
        conn
        |> with_auth(plaintext)
        |> get("/api/v1/me")

      assert %{"data" => %{"id" => id, "email" => email}} = json_response(conn, 200)
      assert id == user.id
      assert email == user.email
    end

    test "un kmn_pat_ inconnu renvoie 401 sans tomber sur le verify JWT", %{conn: conn} do
      conn =
        conn
        |> with_auth("kmn_pat_invalide")
        |> get("/api/v1/me")

      assert json_response(conn, 401)
    end

    test "un kmn_pat_ permet d'appeler les endpoints applicatifs (ex. /residences)", %{conn: conn} do
      user = insert_user!(:membre_cs)
      {:ok, %{plaintext: plaintext}} = ApiTokens.create_token(user, %{"name" => "control"})

      conn =
        conn
        |> with_auth(plaintext)
        |> get("/api/v1/residences")

      # Peu importe le contenu : on vérifie qu'on n'est PAS rejeté par l'auth.
      assert json_response(conn, 200)
    end
  end
end
