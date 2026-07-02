defmodule KomunBackendWeb.OrganizationControllerTest do
  @moduledoc """
  `GET /api/v1/organizations/:id` — lecture d'une organisation.

  Vérifie le gating d'appartenance : un membre (org-scopé OU membre d'un
  bâtiment de l'org) et le super_admin obtiennent 200 ; un non-membre 403 ;
  un id inconnu 404 ; l'absence d'auth 401.
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.{Building, BuildingMember}
  alias KomunBackend.Organizations.Organization
  alias KomunBackend.Repo
  alias KomunBackend.Residences
  alias KomunBackend.Residences.Residence

  defp insert_user!(role, attrs \\ %{}) do
    %User{}
    |> User.changeset(
      Map.merge(
        %{email: "u#{System.unique_integer([:positive])}@test.local", role: role},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp insert_org!(attrs \\ %{}) do
    %Organization{}
    |> Organization.changeset(
      Map.merge(%{name: "Org #{System.unique_integer([:positive])}"}, attrs)
    )
    |> Repo.insert!()
  end

  defp insert_residence!(org) do
    %Residence{}
    |> Residence.initial_changeset(%{
      name: "Résidence #{System.unique_integer([:positive])}",
      join_code: Residences.generate_join_code()
    })
    |> Ecto.Changeset.put_change(:organization_id, org.id)
    |> Repo.insert!()
  end

  defp insert_building!(residence, org) do
    %Building{}
    |> Building.initial_changeset(%{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "2 rue des Lilas",
      city: "Paris",
      postal_code: "75015",
      residence_id: residence.id,
      join_code: KomunBackend.Buildings.generate_join_code()
    })
    |> Ecto.Changeset.put_change(:organization_id, org.id)
    |> Repo.insert!()
  end

  defp add_member!(building, user, role \\ :coproprietaire) do
    %BuildingMember{}
    |> BuildingMember.changeset(%{
      building_id: building.id,
      user_id: user.id,
      role: role,
      is_active: true
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

  describe "GET /api/v1/organizations/:id" do
    test "200 pour un membre org-scopé (organization_id)", %{conn: conn} do
      org = insert_org!(%{name: "Alpha"})
      member = insert_user!(:coproprietaire, %{organization_id: org.id})

      response =
        conn
        |> with_auth(jwt_for(member))
        |> get("/api/v1/organizations/#{org.id}")
        |> json_response(200)

      assert response["data"]["id"] == org.id
      assert response["data"]["name"] == "Alpha"

      for key <- ~w(id name slug type subscription_plan is_active) do
        assert Map.has_key?(response["data"], key), "missing key #{key}"
      end
    end

    test "200 pour un membre d'un bâtiment de l'org (BuildingMember)", %{conn: conn} do
      org = insert_org!()
      residence = insert_residence!(org)
      building = insert_building!(residence, org)
      voisin = insert_user!(:coproprietaire)
      add_member!(building, voisin)

      response =
        conn
        |> with_auth(jwt_for(voisin))
        |> get("/api/v1/organizations/#{org.id}")
        |> json_response(200)

      assert response["data"]["id"] == org.id
    end

    test "200 pour super_admin même non-membre", %{conn: conn} do
      org = insert_org!()
      admin = insert_user!(:super_admin)

      response =
        conn
        |> with_auth(jwt_for(admin))
        |> get("/api/v1/organizations/#{org.id}")
        |> json_response(200)

      assert response["data"]["id"] == org.id
    end

    test "403 pour un utilisateur non-membre", %{conn: conn} do
      org = insert_org!()
      _autre_org = insert_org!()
      outsider = insert_user!(:coproprietaire)

      response =
        conn
        |> with_auth(jwt_for(outsider))
        |> get("/api/v1/organizations/#{org.id}")
        |> json_response(403)

      assert response["error"] == "forbidden"
    end

    test "403 pour un membre d'une AUTRE organisation", %{conn: conn} do
      org = insert_org!()
      other_org = insert_org!()
      member_other = insert_user!(:coproprietaire, %{organization_id: other_org.id})

      conn
      |> with_auth(jwt_for(member_other))
      |> get("/api/v1/organizations/#{org.id}")
      |> json_response(403)
    end

    test "404 pour un id inexistant", %{conn: conn} do
      user = insert_user!(:coproprietaire)
      missing_id = Ecto.UUID.generate()

      response =
        conn
        |> with_auth(jwt_for(user))
        |> get("/api/v1/organizations/#{missing_id}")
        |> json_response(404)

      assert response["error"] == "not_found"
    end

    test "404 pour un id malformé (binary_id invalide)", %{conn: conn} do
      admin = insert_user!(:super_admin)

      conn
      |> with_auth(jwt_for(admin))
      |> get("/api/v1/organizations/not-a-uuid")
      |> json_response(404)
    end

    test "401 sans authentification", %{conn: conn} do
      org = insert_org!()

      conn
      |> get("/api/v1/organizations/#{org.id}")
      |> json_response(401)
    end
  end

  describe "GET /api/v1/organizations/:id/buildings" do
    test "200 liste les bâtiments de l'org pour un membre", %{conn: conn} do
      org = insert_org!()
      residence = insert_residence!(org)
      building = insert_building!(residence, org)
      member = insert_user!(:coproprietaire, %{organization_id: org.id})

      response =
        conn
        |> with_auth(jwt_for(member))
        |> get("/api/v1/organizations/#{org.id}/buildings")
        |> json_response(200)

      ids = Enum.map(response["data"], & &1["id"])
      assert building.id in ids
    end

    test "403 pour un non-membre", %{conn: conn} do
      org = insert_org!()
      outsider = insert_user!(:coproprietaire)

      conn
      |> with_auth(jwt_for(outsider))
      |> get("/api/v1/organizations/#{org.id}/buildings")
      |> json_response(403)
    end
  end
end
