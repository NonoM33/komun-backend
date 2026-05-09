defmodule KomunBackendWeb.Staff.HealthControllerTest do
  @moduledoc """
  TICKET-1.2 — Smoke-test du scope `/api/v1/staff` et du pipeline
  `:require_komun_staff` à travers le route healthcheck.

  Ce contrôleur sert aussi de :
  - balise pour le frontend staff (`staff.komun.app`) qui peut pinger
    cette route pour vérifier la connectivité authentifiée ;
  - smoke-test bout-en-bout dans la suite (auth + plug + scope).
  """

  use KomunBackendWeb.ConnCase, async: true

  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Repo

  defp insert_user!(role) do
    %User{}
    |> User.changeset(%{
      email: "staff#{System.unique_integer([:positive])}@test.local",
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

  describe "GET /api/v1/staff/health" do
    test "200 pour un user :komun_staff", %{conn: conn} do
      user = insert_user!(:komun_staff)

      response =
        conn
        |> with_auth(jwt_for(user))
        |> get("/api/v1/staff/health")
        |> json_response(200)

      assert response["ok"] == true
      assert response["scope"] == "staff"
    end

    test "200 pour un user :super_admin (superset)", %{conn: conn} do
      user = insert_user!(:super_admin)

      response =
        conn
        |> with_auth(jwt_for(user))
        |> get("/api/v1/staff/health")
        |> json_response(200)

      assert response["ok"] == true
    end

    test "403 pour un user :coproprietaire", %{conn: conn} do
      user = insert_user!(:coproprietaire)

      response =
        conn
        |> with_auth(jwt_for(user))
        |> get("/api/v1/staff/health")
        |> json_response(403)

      assert response["error"] == "forbidden"
      assert response["reason"] == "komun_staff_required"
    end

    test "403 pour un user :syndic_manager (n'est PAS staff Komun)", %{conn: conn} do
      user = insert_user!(:syndic_manager)

      conn
      |> with_auth(jwt_for(user))
      |> get("/api/v1/staff/health")
      |> json_response(403)
    end

    test "401 sans header d'autorisation", %{conn: conn} do
      conn
      |> get("/api/v1/staff/health")
      |> json_response(401)
    end
  end
end
