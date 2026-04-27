defmodule KomunBackendWeb.AdminAssistantRuleControllerTest do
  @moduledoc """
  Auth + CRUD contract tests for the per-building AI prompt rules admin
  endpoints. Locks down the rule that only `super_admin` can read or
  mutate them — a syndic / coproprietaire who finds the URL must hit a
  403, not the data.
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Organizations.Organization
  alias KomunBackend.Repo
  alias KomunBackend.Residences.Residence

  defp insert_user!(role) do
    %User{}
    |> User.changeset(%{
      email: "u-#{System.unique_integer([:positive])}@example.com",
      first_name: "T",
      role: role
    })
    |> Repo.insert!()
  end

  defp insert_building! do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    suffix = System.unique_integer([:positive])

    {:ok, org} =
      Repo.insert(%Organization{
        name: "Org #{suffix}",
        slug: "org-#{suffix}",
        inserted_at: now,
        updated_at: now
      })

    code =
      "R" <>
        (System.unique_integer([:positive])
         |> Integer.to_string()
         |> String.pad_leading(7, "0"))

    {:ok, residence} =
      Repo.insert(%Residence{
        name: "Résidence #{code}",
        slug: "residence-#{String.downcase(code)}",
        join_code: code,
        is_active: true,
        inserted_at: now,
        updated_at: now
      })

    bcode =
      "B" <>
        (System.unique_integer([:positive])
         |> Integer.to_string()
         |> String.pad_leading(7, "0"))

    Repo.insert!(%Building{
      name: "Bâtiment #{suffix}",
      address: "10 rue X",
      city: "Paris",
      postal_code: "75001",
      country: "FR",
      is_active: true,
      organization_id: org.id,
      residence_id: residence.id,
      join_code: bcode,
      inserted_at: now,
      updated_at: now
    })
  end

  defp authed_conn(conn, user) do
    {:ok, token, _} = Guardian.encode_and_sign(user, %{}, ttl: {1, :hour})
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "auth gate" do
    test "401 without a token", %{conn: conn} do
      b = insert_building!()
      assert conn |> get("/api/v1/admin/buildings/#{b.id}/assistant-rules") |> response(401)
    end

    test "403 for a syndic_manager", %{conn: conn} do
      b = insert_building!()
      user = insert_user!(:syndic_manager)

      response =
        conn
        |> authed_conn(user)
        |> get("/api/v1/admin/buildings/#{b.id}/assistant-rules")

      assert json_response(response, 403)["error"] == "Forbidden"
    end

    test "403 for a coproprietaire", %{conn: conn} do
      b = insert_building!()
      user = insert_user!(:coproprietaire)

      response =
        conn
        |> authed_conn(user)
        |> get("/api/v1/admin/buildings/#{b.id}/assistant-rules")

      assert json_response(response, 403)["error"] == "Forbidden"
    end

    test "200 for super_admin on an empty building", %{conn: conn} do
      b = insert_building!()
      user = insert_user!(:super_admin)

      response =
        conn
        |> authed_conn(user)
        |> get("/api/v1/admin/buildings/#{b.id}/assistant-rules")

      assert json_response(response, 200) == %{"data" => []}
    end
  end

  describe "create + list as super_admin" do
    test "creates a rule and returns it in subsequent list", %{conn: conn} do
      b = insert_building!()
      admin = insert_user!(:super_admin)

      created =
        conn
        |> authed_conn(admin)
        |> post("/api/v1/admin/buildings/#{b.id}/assistant-rules", %{
          "content" => "Si ça gène un voisin, c'est interdit."
        })
        |> json_response(201)

      assert created["data"]["content"] == "Si ça gène un voisin, c'est interdit."
      assert created["data"]["enabled"] == true

      listed =
        conn
        |> authed_conn(admin)
        |> get("/api/v1/admin/buildings/#{b.id}/assistant-rules")
        |> json_response(200)

      assert length(listed["data"]) == 1
      assert hd(listed["data"])["id"] == created["data"]["id"]
    end

    test "rejects empty content with 422", %{conn: conn} do
      b = insert_building!()
      admin = insert_user!(:super_admin)

      response =
        conn
        |> authed_conn(admin)
        |> post("/api/v1/admin/buildings/#{b.id}/assistant-rules", %{"content" => "  "})

      assert json_response(response, 422)["errors"]
    end
  end

  describe "update + delete as super_admin" do
    test "patch updates the content and toggles enabled", %{conn: conn} do
      b = insert_building!()
      admin = insert_user!(:super_admin)

      created =
        conn
        |> authed_conn(admin)
        |> post("/api/v1/admin/buildings/#{b.id}/assistant-rules", %{"content" => "old"})
        |> json_response(201)

      id = created["data"]["id"]

      updated =
        conn
        |> authed_conn(admin)
        |> patch("/api/v1/admin/buildings/#{b.id}/assistant-rules/#{id}", %{
          "content" => "new wording",
          "enabled" => false
        })
        |> json_response(200)

      assert updated["data"]["content"] == "new wording"
      assert updated["data"]["enabled"] == false
    end

    test "delete removes the rule", %{conn: conn} do
      b = insert_building!()
      admin = insert_user!(:super_admin)

      created =
        conn
        |> authed_conn(admin)
        |> post("/api/v1/admin/buildings/#{b.id}/assistant-rules", %{"content" => "doomed"})
        |> json_response(201)

      id = created["data"]["id"]

      response =
        conn
        |> authed_conn(admin)
        |> delete("/api/v1/admin/buildings/#{b.id}/assistant-rules/#{id}")

      assert json_response(response, 200)["message"] == "Rule deleted"

      remaining =
        conn
        |> authed_conn(admin)
        |> get("/api/v1/admin/buildings/#{b.id}/assistant-rules")
        |> json_response(200)

      assert remaining["data"] == []
    end

    test "404 when the rule belongs to another building", %{conn: conn} do
      b1 = insert_building!()
      b2 = insert_building!()
      admin = insert_user!(:super_admin)

      created =
        conn
        |> authed_conn(admin)
        |> post("/api/v1/admin/buildings/#{b1.id}/assistant-rules", %{"content" => "rule"})
        |> json_response(201)

      id = created["data"]["id"]

      response =
        conn
        |> authed_conn(admin)
        |> patch("/api/v1/admin/buildings/#{b2.id}/assistant-rules/#{id}", %{"content" => "x"})

      assert json_response(response, 404)
    end
  end
end
