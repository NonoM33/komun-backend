defmodule KomunBackendWeb.BuildingVerifyCodeTest do
  use KomunBackendWeb.ConnCase

  alias KomunBackend.Repo
  alias KomunBackend.Buildings
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Organizations.Organization

  defp insert_building!(code) do
    {:ok, org} =
      %Organization{}
      |> Organization.changeset(%{name: "Org #{System.unique_integer([:positive])}"})
      |> Repo.insert()

    %Building{}
    |> Building.changeset(%{
      name: "Résidence Test",
      address: "10 rue des Lilas",
      city: "Paris",
      postal_code: "75001",
      organization_id: org.id,
      join_code: code
    })
    |> Repo.insert!()
  end

  test "returns the building when code matches", %{conn: conn} do
    _b = insert_building!("VERIFY01")

    conn = get(conn, ~p"/api/v1/buildings/verify_code?code=VERIFY01")
    body = json_response(conn, 200)

    assert body["valid"] == true
    assert body["building"]["name"] == "Résidence Test"
    assert body["building"]["city"] == "Paris"
  end

  test "matches codes case-insensitively (same as join_by_code)", %{conn: conn} do
    insert_building!("CASEINS9")

    body =
      conn
      |> get(~p"/api/v1/buildings/verify_code?code=caseins9")
      |> json_response(200)

    assert body["valid"] == true
  end

  test "trims surrounding whitespace", %{conn: conn} do
    insert_building!("TRIMME23")

    body =
      conn
      |> get(~p"/api/v1/buildings/verify_code?code=%20TRIMME23%20")
      |> json_response(200)

    assert body["valid"] == true
  end

  test "returns 404 when the code is unknown", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/buildings/verify_code?code=NOTREAL1")
    body = json_response(conn, 404)

    assert body["valid"] == false
    assert body["error"] == "invalid_code"
  end

  test "returns 400 when the code param is missing", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/buildings/verify_code")
    body = json_response(conn, 400)

    assert body["valid"] == false
    assert body["error"] == "missing_code"
  end

  test "returns 400 when the code is blank", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/buildings/verify_code?code=")
    body = json_response(conn, 400)

    assert body["valid"] == false
  end

  test "does NOT return buildings that are inactive", %{conn: conn} do
    # Flip is_active off so the building should no longer be discoverable
    # via the public short-code endpoint.
    b = insert_building!("INACTIV4")
    b |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

    # Sanity check: Buildings.get_building_by_join_code filters is_active.
    assert is_nil(Buildings.get_building_by_join_code("INACTIV4"))

    conn = get(conn, ~p"/api/v1/buildings/verify_code?code=INACTIV4")
    assert json_response(conn, 404)["valid"] == false
  end
end
