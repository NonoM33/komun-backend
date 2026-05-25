defmodule KomunBackendWeb.AdminPromoteKomunStaffTest do
  @moduledoc """
  TICKET-1.3 — `POST /api/v1/admin/users/:id/promote-to-komun-staff`.

  Promote un user existant en `:komun_staff`. Idempotent. Refuse de
  rétrograder un `:super_admin`. Gated `super_admin` (un komun_staff
  ne peut pas s'auto-promouvoir, ni promouvoir un autre).

  Couvre aussi l'extension de `PUT /api/v1/admin/users/:id/role` pour
  accepter `"komun_staff"` comme valeur (cohérence avec l'enum schema).
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Repo

  defp insert_user!(role) do
    %User{}
    |> User.changeset(%{
      email: "u#{System.unique_integer([:positive])}@test.local",
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

  describe "POST /api/v1/admin/users/:id/promote-to-komun-staff" do
    test "promote un :coproprietaire en :komun_staff (200, rôle persisté en DB)",
         %{conn: conn} do
      admin = insert_user!(:super_admin)
      target = insert_user!(:coproprietaire)

      response =
        conn
        |> with_auth(jwt_for(admin))
        |> post("/api/v1/admin/users/#{target.id}/promote-to-komun-staff")
        |> json_response(200)

      assert response["data"]["id"] == target.id
      assert response["data"]["role"] == "komun_staff"

      # Persisté
      assert Repo.get!(User, target.id).role == :komun_staff
    end

    test "idempotent : si déjà :komun_staff → 200 sans erreur ni double mutation",
         %{conn: conn} do
      admin = insert_user!(:super_admin)
      target = insert_user!(:komun_staff)
      original_updated_at = target.updated_at

      response =
        conn
        |> with_auth(jwt_for(admin))
        |> post("/api/v1/admin/users/#{target.id}/promote-to-komun-staff")
        |> json_response(200)

      assert response["data"]["role"] == "komun_staff"

      # On vérifie que l'updated_at n'a pas bougé : pas de re-update
      reloaded = Repo.get!(User, target.id)
      assert reloaded.role == :komun_staff
      assert reloaded.updated_at == original_updated_at
    end

    test "refuse de rétrograder un :super_admin → 422 cannot_demote_super_admin",
         %{conn: conn} do
      admin = insert_user!(:super_admin)
      target = insert_user!(:super_admin)

      response =
        conn
        |> with_auth(jwt_for(admin))
        |> post("/api/v1/admin/users/#{target.id}/promote-to-komun-staff")
        |> json_response(422)

      assert response["error"] == "cannot_demote_super_admin"

      # Pas de mutation
      assert Repo.get!(User, target.id).role == :super_admin
    end

    test "user n'existe pas → 404", %{conn: conn} do
      admin = insert_user!(:super_admin)

      response =
        conn
        |> with_auth(jwt_for(admin))
        |> post("/api/v1/admin/users/00000000-0000-0000-0000-000000000000/promote-to-komun-staff")
        |> json_response(404)

      assert response["error"] =~ "not found" or response["error"] =~ "User not found"
    end

    test "un komun_staff (pas super_admin) ne peut PAS promouvoir → 403", %{conn: conn} do
      caller = insert_user!(:komun_staff)
      target = insert_user!(:coproprietaire)

      conn
      |> with_auth(jwt_for(caller))
      |> post("/api/v1/admin/users/#{target.id}/promote-to-komun-staff")
      |> json_response(403)

      # Pas de mutation
      assert Repo.get!(User, target.id).role == :coproprietaire
    end

    test "un coproprietaire est rejeté → 403", %{conn: conn} do
      caller = insert_user!(:coproprietaire)
      target = insert_user!(:locataire)

      conn
      |> with_auth(jwt_for(caller))
      |> post("/api/v1/admin/users/#{target.id}/promote-to-komun-staff")
      |> json_response(403)
    end

    test "sans authentification → 401", %{conn: conn} do
      target = insert_user!(:coproprietaire)

      conn
      |> post("/api/v1/admin/users/#{target.id}/promote-to-komun-staff")
      |> json_response(401)
    end
  end

  describe "PUT /api/v1/admin/users/:id/role with role=komun_staff (cohérence)" do
    test "accepte role=komun_staff (n'était pas dans le whitelist avant 1.1)",
         %{conn: conn} do
      admin = insert_user!(:super_admin)
      target = insert_user!(:locataire)

      response =
        conn
        |> with_auth(jwt_for(admin))
        |> put("/api/v1/admin/users/#{target.id}/role", %{"role" => "komun_staff"})
        |> json_response(200)

      assert response["data"]["role"] == "komun_staff"
      assert Repo.get!(User, target.id).role == :komun_staff
    end
  end
end
