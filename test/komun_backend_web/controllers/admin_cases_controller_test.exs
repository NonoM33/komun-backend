defmodule KomunBackendWeb.AdminCasesControllerTest do
  use KomunBackendWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Repo

  alias KomunBackend.{Accounts, Buildings, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Residences.Residence

  defp make_user!(role \\ :super_admin) do
    %User{}
    |> User.changeset(%{
      email: "admin-#{System.unique_integer([:positive])}@komun.test",
      role: role
    })
    |> Repo.insert!()
  end

  defp make_building!() do
    {:ok, residence} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: "R-#{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> Repo.insert()

    %Building{}
    |> Building.initial_changeset(%{
      name: "B-#{System.unique_integer([:positive])}",
      address: "1 rue Test",
      city: "Paris",
      postal_code: "75001",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    })
    |> Repo.insert!()
  end

  defp authed_conn(conn, user) do
    {:ok, token, _claims} = Guardian.encode_and_sign(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "POST /api/v1/admin/buildings/:building_id/cases/batch" do
    test "rejects non-super-admin", %{conn: conn} do
      user = make_user!(:coproprietaire)
      building = make_building!()

      payload = %{"cases" => [%{"type" => "incident", "title" => "x", "description" => "y"}]}

      response =
        conn
        |> authed_conn(user)
        |> post("/api/v1/admin/buildings/#{building.id}/cases/batch", payload)

      assert response.status in [401, 403]
    end

    test "creates incidents/doleances/diligences in brouillon status", %{conn: conn} do
      admin = make_user!(:super_admin)
      building = make_building!()

      payload = %{
        "cases" => [
          %{
            "type" => "incident",
            "title" => "Chauffage hall A",
            "description" => "Le chauffagiste n'a pas pu intervenir.",
            "category" => "ascenseur",
            "severity" => "medium"
          },
          %{
            "type" => "doleance",
            "title" => "Encombrants trottoir",
            "description" => "Matelas abandonnés depuis une semaine."
          },
          %{
            "type" => "diligence",
            "title" => "Nuisances olfactives lot 14",
            "description" => "Odeurs répétées",
            "source_type" => "copro_owner"
          }
        ]
      }

      response =
        conn
        |> authed_conn(admin)
        |> post("/api/v1/admin/buildings/#{building.id}/cases/batch", payload)

      assert response.status == 201
      body = Jason.decode!(response.resp_body)
      assert length(body["data"]["created"]) == 3
      assert body["data"]["errors"] == []

      Enum.each(body["data"]["created"], fn entry ->
        assert entry["status"] == "brouillon"
        assert entry["id"]
      end)

      # On vérifie qu'aucun incident :open n'a été créé (pas de leak vers les résidents).
      assert Repo.aggregate(
               from(i in KomunBackend.Incidents.Incident,
                 where:
                   i.building_id == ^building.id and i.status != :brouillon
               ),
               :count
             ) == 0
    end

    test "rejects unknown `type` per item without blocking the rest", %{conn: conn} do
      admin = make_user!(:super_admin)
      building = make_building!()

      payload = %{
        "cases" => [
          %{
            "type" => "incident",
            "title" => "Incident valide",
            "description" => "Description suffisante."
          },
          %{"type" => "vote", "title" => "Pas un dossier"}
        ]
      }

      response =
        conn
        |> authed_conn(admin)
        |> post("/api/v1/admin/buildings/#{building.id}/cases/batch", payload)

      assert response.status == 201
      body = Jason.decode!(response.resp_body)
      assert length(body["data"]["created"]) == 1
      assert length(body["data"]["errors"]) == 1
      assert hd(body["data"]["errors"])["error"] == "invalid_type"
    end
  end

end
