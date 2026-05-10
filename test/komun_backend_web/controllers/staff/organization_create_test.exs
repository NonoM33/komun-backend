defmodule KomunBackendWeb.Staff.OrganizationCreateTest do
  @moduledoc """
  TICKET-2.5 — `POST /api/v1/staff/organizations` : création d'une
  organisation cliente sales-led, avec onboarding du primary manager
  via magic-link.
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Organizations.Organization
  alias KomunBackend.Repo

  defp insert_user!(role, attrs \\ %{}) do
    %User{}
    |> User.changeset(
      Map.merge(
        %{
          email: "u#{System.unique_integer([:positive])}@test.local",
          role: role
        },
        attrs
      )
    )
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
        "type" => "syndic",
        "billing_email" => "billing-#{System.unique_integer([:positive])}@example.com",
        "plan" => "pro",
        "primary_manager" => %{
          "email" => "manager-#{System.unique_integer([:positive])}@example.com",
          "first_name" => "Marc",
          "last_name" => "Dupond"
        }
      },
      overrides
    )
  end

  describe "POST /api/v1/staff/organizations" do
    test "201 happy path : org créée, manager créé, magic-link renvoyé",
         %{conn: conn} do
      staff = insert_user!(:komun_staff)

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations", valid_payload())
        |> json_response(201)

      assert response["data"]["organization"]["name"] == "Résidence des Tilleuls"
      assert response["data"]["organization"]["type"] == "syndic"
      assert response["data"]["organization"]["subscription_plan"] == "pro"
      assert response["data"]["primary_manager"]["role"] == "syndic_manager"
      assert is_binary(response["data"]["magic_link"]["url"])
      assert is_binary(response["data"]["magic_link"]["code"])
      assert response["data"]["magic_link"]["expires_in_minutes"] == 15

      org_id = response["data"]["organization"]["id"]
      manager_id = response["data"]["primary_manager"]["id"]
      org = Repo.get!(Organization, org_id)
      manager = Repo.get!(User, manager_id)

      # Persistance vérifiée
      assert manager.role == :syndic_manager
      assert manager.organization_id == org.id
    end

    test "201 si le manager existe déjà sans organization (réutilise le user)",
         %{conn: conn} do
      staff = insert_user!(:komun_staff)
      existing = insert_user!(:coproprietaire, %{email: "marc@existing.com"})

      payload =
        valid_payload(%{
          "primary_manager" => %{
            "email" => "marc@existing.com",
            "first_name" => "Marc"
          }
        })

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations", payload)
        |> json_response(201)

      assert response["data"]["primary_manager"]["id"] == existing.id

      reloaded = Repo.get!(User, existing.id)
      assert reloaded.role == :syndic_manager
      assert reloaded.organization_id == response["data"]["organization"]["id"]
    end

    test "422 si le manager existe déjà avec une autre organization",
         %{conn: conn} do
      staff = insert_user!(:komun_staff)

      other_org =
        %Organization{}
        |> Organization.changeset(%{name: "Autre Org"})
        |> Repo.insert!()

      _existing =
        insert_user!(:syndic_manager, %{
          email: "marc@elsewhere.com",
          organization_id: other_org.id
        })

      payload =
        valid_payload(%{
          "primary_manager" => %{
            "email" => "marc@elsewhere.com",
            "first_name" => "Marc"
          }
        })

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations", payload)
        |> json_response(422)

      assert response["error"] == "user_belongs_to_another_org"
    end

    test "422 si le name est manquant", %{conn: conn} do
      staff = insert_user!(:komun_staff)

      payload = valid_payload() |> Map.delete("name")

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations", payload)
        |> json_response(422)

      assert is_map(response["errors"])
    end

    test "422 si plan inconnu", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      payload = valid_payload(%{"plan" => "platinum"})

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations", payload)
        |> json_response(422)

      assert response["error"] == "invalid_plan"
      assert is_list(response["allowed"])
    end

    test "422 si type inconnu", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      payload = valid_payload(%{"type" => "trust"})

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations", payload)
        |> json_response(422)

      assert response["error"] == "invalid_type"
    end

    test "422 si primary_manager.email invalide", %{conn: conn} do
      staff = insert_user!(:komun_staff)

      payload =
        valid_payload(%{
          "primary_manager" => %{"email" => "not-an-email", "first_name" => "X"}
        })

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations", payload)
        |> json_response(422)

      assert is_map(response["errors"])
    end

    test "422 si primary_manager manquant", %{conn: conn} do
      staff = insert_user!(:komun_staff)
      payload = valid_payload() |> Map.delete("primary_manager")

      response =
        conn
        |> with_auth(jwt_for(staff))
        |> post("/api/v1/staff/organizations", payload)
        |> json_response(422)

      assert response["error"] == "primary_manager_required"
    end

    test "403 pour un voisin", %{conn: conn} do
      voisin = insert_user!(:coproprietaire)

      conn
      |> with_auth(jwt_for(voisin))
      |> post("/api/v1/staff/organizations", valid_payload())
      |> json_response(403)
    end

    test "401 sans authentification", %{conn: conn} do
      conn
      |> post("/api/v1/staff/organizations", valid_payload())
      |> json_response(401)
    end
  end
end
