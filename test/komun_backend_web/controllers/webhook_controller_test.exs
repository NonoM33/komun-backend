defmodule KomunBackendWeb.WebhookControllerTest do
  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.Repo
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Buildings
  alias KomunBackend.Residences
  alias KomunBackend.Residences.Residence

  @secret "test-resend-secret-1234"

  setup do
    System.put_env("RESEND_INBOUND_SECRET", @secret)
    on_exit(fn -> System.delete_env("RESEND_INBOUND_SECRET") end)
    :ok
  end

  defp make_admin! do
    %User{}
    |> User.changeset(%{
      email: "admin-#{System.unique_integer([:positive])}@komun.test",
      role: :super_admin
    })
    |> Repo.insert!()
  end

  defp make_building!(alias_str) do
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
      join_code: Buildings.generate_join_code(),
      inbound_alias: alias_str
    })
    |> Repo.insert!()
  end

  defp post_inbound(conn, payload, token \\ @secret) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> post("/api/v1/webhooks/resend/inbound", payload)
  end

  test "rejects without auth", %{conn: conn} do
    response = post(conn, "/api/v1/webhooks/resend/inbound", %{})
    assert response.status == 401
  end

  test "rejects with wrong secret", %{conn: conn} do
    response = post_inbound(conn, %{}, "wrong")
    assert response.status == 401
  end

  test "404 when no building matches the to-address alias", %{conn: conn} do
    _ = make_admin!()
    payload = %{
      "from" => %{"email" => "voisin@gmail.com", "name" => "Voisin"},
      "to" => [%{"email" => "no-such-alias@inbound.komun.app"}],
      "subject" => "Test",
      "text" => "Bonjour"
    }
    response = post_inbound(conn, payload)
    assert response.status == 404
  end

  test "creates a brouillon incident when no match", %{conn: conn} do
    _admin = make_admin!()
    building = make_building!("test-alias-1")

    payload = %{
      "from" => %{"email" => "voisin@gmail.com", "name" => "Voisin Inquiet"},
      "to" => [%{"email" => "test-alias-1@inbound.komun.app"}],
      "subject" => "Panne ascenseur urgente",
      "text" => "Bonjour, depuis ce matin l'ascenseur ne répond plus...",
      "date" => "2026-04-28T10:00:00Z"
    }

    response = post_inbound(conn, payload)
    assert response.status == 201
    body = Jason.decode!(response.resp_body)
    assert body["data"]["action"] == "created"
    assert body["data"]["incident_id"]

    # Le statut est brouillon, le commentaire 📧 est posé
    incidents = KomunBackend.Incidents.list_incidents(building.id, %{}, _admin = make_admin!())
    # En tant que super_admin, on voit les brouillons
    incident =
      Enum.find(incidents, &(&1.id == body["data"]["incident_id"])) ||
        KomunBackend.Incidents.get_incident!(body["data"]["incident_id"])

    assert incident.status == :brouillon
    assert incident.title == "Panne ascenseur urgente"
  end

  test "appends a comment when an incident with same subject exists", %{conn: conn} do
    admin = make_admin!()
    building = make_building!("test-alias-2")

    {:ok, existing} =
      KomunBackend.Incidents.create_incident(building.id, admin.id, %{
        "title" => "Fuite parking -2",
        "description" => "Initial",
        "category" => "plomberie",
        "severity" => "high",
        "status" => "open"
      })

    payload = %{
      "from" => %{"email" => "voisin@gmail.com", "name" => "Voisin"},
      "to" => [%{"email" => "test-alias-2@inbound.komun.app"}],
      "subject" => "Fuite parking -2",
      "text" => "Mise à jour : la flaque s'élargit"
    }

    response = post_inbound(conn, payload)
    assert response.status == 200
    body = Jason.decode!(response.resp_body)
    assert body["data"]["action"] == "appended"
    assert body["data"]["incident_id"] == existing.id
  end
end
