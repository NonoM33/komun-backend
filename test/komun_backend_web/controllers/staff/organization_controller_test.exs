defmodule KomunBackendWeb.Staff.OrganizationControllerTest do
  @moduledoc """
  TICKET-2.3 — `GET /api/v1/staff/organizations` : liste paginée des
  orgs clientes pour le portail staff.
  """

  use KomunBackendWeb.ConnCase, async: false

  import Ecto.Query

  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Organizations.Organization
  alias KomunBackend.Repo

  defp insert_user!(role) do
    %User{}
    |> User.changeset(%{
      email: "u#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp insert_org!(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert!()
  end

  defp jwt_for(user) do
    {:ok, token, _} = Guardian.encode_and_sign(user, %{}, ttl: {1, :hour})
    token
  end

  defp with_auth(conn, jwt) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{jwt}")
  end

  describe "GET /api/v1/staff/organizations" do
    test "200 + payload paginé pour un komun_staff", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      _o1 = insert_org!(%{name: "Alpha"})
      _o2 = insert_org!(%{name: "Beta"})

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> get("/api/v1/staff/organizations")
        |> json_response(200)

      assert is_list(response["data"])
      assert length(response["data"]) == 2

      [first | _] = response["data"]

      for key <- ~w(id name slug type subscription_plan is_active
                    residences_count members_count inserted_at) do
        assert Map.has_key?(first, key), "missing key #{key} in #{inspect(first)}"
      end

      assert response["meta"]["page"] == 1
      assert response["meta"]["per_page"] == 25
      assert response["meta"]["total"] == 2
    end

    test "200 pour super_admin (superset)", %{conn: conn} do
      admin = insert_user!(:super_admin)
      insert_org!(%{name: "Solo"})

      conn
      |> with_auth(jwt_for(admin))
      |> get("/api/v1/staff/organizations")
      |> json_response(200)
    end

    test "403 pour un user :coproprietaire", %{conn: conn} do
      voisin = insert_user!(:coproprietaire)
      insert_org!(%{name: "Solo"})

      response =
        conn
        |> with_auth(jwt_for(voisin))
        |> get("/api/v1/staff/organizations")
        |> json_response(403)

      assert response["reason"] == "komun_staff_required"
    end

    test "401 sans authentification", %{conn: conn} do
      conn
      |> get("/api/v1/staff/organizations")
      |> json_response(401)
    end

    test "filtre par plan via query string", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      free = insert_org!(%{name: "Free Co"})
      pro = insert_org!(%{name: "Pro Co"})

      Repo.update_all(
        from(o in Organization, where: o.id == ^pro.id),
        set: [subscription_plan: :pro]
      )

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> get("/api/v1/staff/organizations?plan=pro")
        |> json_response(200)

      assert length(response["data"]) == 1
      assert hd(response["data"])["id"] == pro.id

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> get("/api/v1/staff/organizations?plan=free")
        |> json_response(200)

      assert hd(response["data"])["id"] == free.id
    end

    test "filtre par recherche q", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      tilleuls = insert_org!(%{name: "Résidence des Tilleuls"})
      _other = insert_org!(%{name: "Le Clos Saint-Michel"})

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> get("/api/v1/staff/organizations?q=tilleuls")
        |> json_response(200)

      assert length(response["data"]) == 1
      assert hd(response["data"])["id"] == tilleuls.id
    end

    test "plan invalide → 422 avec liste des valeurs autorisées", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      insert_org!(%{name: "Solo"})

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> get("/api/v1/staff/organizations?plan=ultra")
        |> json_response(422)

      assert response["error"] == "invalid_plan"
      assert is_list(response["allowed"])
    end

    test "page > total → 200 avec data vide (PAS 404)", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      insert_org!(%{name: "Solo"})

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> get("/api/v1/staff/organizations?page=99")
        |> json_response(200)

      assert response["data"] == []
      assert response["meta"]["page"] == 99
    end

    test "compte les résidences et membres rattachés", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      org = insert_org!(%{name: "Avec data"})

      # On rattache 2 résidences
      for n <- 1..2 do
        %KomunBackend.Residences.Residence{}
        |> Ecto.Changeset.change(
          name: "Res #{n}",
          slug: "res-#{n}-#{System.unique_integer([:positive])}",
          join_code: "R#{n}#{System.unique_integer([:positive])}",
          organization_id: org.id
        )
        |> Repo.insert!()
      end

      # On rattache 3 users
      for _ <- 1..3 do
        %User{}
        |> Ecto.Changeset.change(
          email: "m#{System.unique_integer([:positive])}@test.local",
          role: :coproprietaire,
          organization_id: org.id
        )
        |> Repo.insert!()
      end

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> get("/api/v1/staff/organizations")
        |> json_response(200)

      [entry] = Enum.filter(response["data"], &(&1["id"] == org.id))
      assert entry["residences_count"] == 2
      assert entry["members_count"] == 3
    end
  end
end
