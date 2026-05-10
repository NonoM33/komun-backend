defmodule KomunBackendWeb.Staff.ResidenceProvisionTest do
  @moduledoc """
  TICKET-6.1 — `POST /api/v1/staff/organizations/:id/residences` :
  provisionne une résidence + ses bâtiments + génère un `join_code`
  unique pour chacun (règle SACRÉE : immuable post-création, cf. CLAUDE.md).
  """

  use KomunBackendWeb.ConnCase, async: false

  import Ecto.Query

  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Organizations.Organization
  alias KomunBackend.Repo
  alias KomunBackend.Residences.Residence

  defp insert_user!(role) do
    %User{}
    |> User.changeset(%{
      email: "u#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp insert_org!(attrs \\ %{name: "Test Org"}) do
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

  defp valid_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Résidence des Tilleuls",
        "address" => "12 rue des Tilleuls",
        "city" => "Paris",
        "postal_code" => "75011",
        "buildings" => [
          %{"name" => "Bâtiment A", "address" => "12 rue des Tilleuls"},
          %{"name" => "Bâtiment B", "address" => "12bis rue des Tilleuls"}
        ]
      },
      overrides
    )
  end

  describe "POST /api/v1/staff/organizations/:id/residences" do
    test "201 happy path : résidence + 2 bâtiments + join_codes uniques",
         %{conn: conn} do
      staff = insert_user!(:komun_staff)
      org = insert_org!()

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations/#{org.id}/residences", valid_payload())
        |> json_response(201)

      assert response["data"]["residence"]["name"] == "Résidence des Tilleuls"
      assert response["data"]["residence"]["organization_id"] == org.id
      assert is_binary(response["data"]["residence"]["join_code"])

      buildings = response["data"]["buildings"]
      assert length(buildings) == 2

      codes = Enum.map(buildings, & &1["join_code"])
      assert Enum.all?(codes, &is_binary/1)
      # Uniques entre eux
      assert length(Enum.uniq(codes)) == 2
      # Ne sont pas le même que la résidence
      refute response["data"]["residence"]["join_code"] in codes

      # Persistance
      residence = Repo.get!(Residence, response["data"]["residence"]["id"])
      assert residence.organization_id == org.id

      db_buildings =
        Repo.all(
          from b in Building,
            where: b.residence_id == ^residence.id,
            order_by: [asc: b.name]
        )

      assert length(db_buildings) == 2
      assert Enum.all?(db_buildings, &(&1.organization_id == org.id))
    end

    test "201 fonctionne avec un seul bâtiment", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      org = insert_org!()

      payload =
        valid_payload(%{
          "buildings" => [
            %{"name" => "Unique", "address" => "1 rue Test"}
          ]
        })

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations/#{org.id}/residences", payload)
        |> json_response(201)

      assert length(response["data"]["buildings"]) == 1
    end

    test "422 si pas de bâtiment fourni", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      org = insert_org!()
      payload = valid_payload(%{"buildings" => []})

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations/#{org.id}/residences", payload)
        |> json_response(422)

      assert response["error"] == "no_buildings_provided"
    end

    test "422 si la clé buildings manque", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      org = insert_org!()
      payload = valid_payload() |> Map.delete("buildings")

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations/#{org.id}/residences", payload)
        |> json_response(422)

      assert response["error"] == "no_buildings_provided"
    end

    test "404 si l'organisation n'existe pas", %{conn: conn} do
      staff = insert_user!(:komun_staff)

      conn
      |> with_auth(jwt_for(staff))
      |> post(
        "/api/v1/staff/organizations/00000000-0000-0000-0000-000000000000/residences",
        valid_payload()
      )
      |> json_response(404)
    end

    test "422 organization_suspended si org is_active=false", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      org = insert_org!()

      Repo.update_all(
        from(o in Organization, where: o.id == ^org.id),
        set: [is_active: false]
      )

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations/#{org.id}/residences", valid_payload())
        |> json_response(422)

      assert response["error"] == "organization_suspended"
    end

    test "422 changeset si la résidence a un name invalide", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      org = insert_org!()
      payload = valid_payload(%{"name" => "X"})

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations/#{org.id}/residences", payload)
        |> json_response(422)

      assert is_map(response["errors"])
    end

    test "join_code n'est PAS castable depuis le payload (règle sacrée)",
         %{conn: conn} do
      staff = insert_user!(:komun_staff)
      org = insert_org!()

      payload =
        valid_payload(%{
          "join_code" => "MYCUSTOM",
          "buildings" => [
            %{"name" => "B1", "address" => "1 rue", "join_code" => "ALSOCUSTOM"}
          ]
        })

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations/#{org.id}/residences", payload)
        |> json_response(201)

      # On a bien un code mais PAS celui demandé : il est généré côté serveur
      assert response["data"]["residence"]["join_code"] != "MYCUSTOM"

      [b] = response["data"]["buildings"]
      assert b["join_code"] != "ALSOCUSTOM"
    end

    test "403 pour un voisin", %{conn: conn} do
      voisin = insert_user!(:coproprietaire)
      org = insert_org!()

      conn
      |> with_auth(jwt_for(voisin))
      |> post("/api/v1/staff/organizations/#{org.id}/residences", valid_payload())
      |> json_response(403)
    end

    test "401 sans authentification", %{conn: conn} do
      org = insert_org!()

      conn
      |> post("/api/v1/staff/organizations/#{org.id}/residences", valid_payload())
      |> json_response(401)
    end
  end
end
