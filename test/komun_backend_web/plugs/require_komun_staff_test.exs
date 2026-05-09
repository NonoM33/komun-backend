defmodule KomunBackendWeb.Plugs.RequireKomunStaffTest do
  @moduledoc """
  TICKET-1.1 / TICKET-1.2 — Le plug `RequireKomunStaff` laisse passer
  les rôles `:komun_staff` et `:super_admin`, et halt en 403 pour tout
  le reste.
  """

  use KomunBackendWeb.ConnCase, async: true

  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Repo
  alias KomunBackendWeb.Plugs.RequireKomunStaff

  defp insert_user!(role) do
    %User{}
    |> User.changeset(%{
      email: "staff#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp build_conn_with_user(conn, user) do
    Guardian.Plug.put_current_resource(conn, user)
  end

  describe "call/2" do
    test "laisse passer un user :komun_staff", %{conn: conn} do
      user = insert_user!(:komun_staff)

      result =
        conn
        |> build_conn_with_user(user)
        |> RequireKomunStaff.call([])

      refute result.halted
      assert result.status in [nil, 200]
    end

    test "laisse passer un user :super_admin", %{conn: conn} do
      user = insert_user!(:super_admin)

      result =
        conn
        |> build_conn_with_user(user)
        |> RequireKomunStaff.call([])

      refute result.halted
    end

    test "rejette un user :coproprietaire avec 403 + body explicite", %{conn: conn} do
      user = insert_user!(:coproprietaire)

      result =
        conn
        |> build_conn_with_user(user)
        |> RequireKomunStaff.call([])

      assert result.halted
      assert result.status == 403

      body = Jason.decode!(result.resp_body)
      assert body["error"] == "forbidden"
      assert body["reason"] == "komun_staff_required"
    end

    test "rejette un user :syndic_manager (n'est PAS staff Komun)", %{conn: conn} do
      user = insert_user!(:syndic_manager)

      result =
        conn
        |> build_conn_with_user(user)
        |> RequireKomunStaff.call([])

      assert result.halted
      assert result.status == 403
    end

    test "rejette une absence de user (current_resource nil) avec 403", %{conn: conn} do
      result = RequireKomunStaff.call(conn, [])

      assert result.halted
      assert result.status == 403
    end
  end
end
