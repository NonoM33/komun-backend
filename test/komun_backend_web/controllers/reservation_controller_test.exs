defmodule KomunBackendWeb.ReservationControllerTest do
  @moduledoc """
  Tests d'intégration des endpoints de réservation. La logique métier
  est couverte par `KomunBackend.ReservationsTest` ; ici on vérifie
  juste l'enrobage HTTP : auth, sérialisation, codes statut.
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.{Buildings, Repo, Reservations, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.{Building, Lot}
  alias KomunBackend.Residences.Residence

  defp insert_residence! do
    {:ok, r} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: "Rés #{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> Repo.insert()

    r
  end

  defp insert_building!(residence) do
    %Building{}
    |> Building.initial_changeset(%{
      name: "B #{System.unique_integer([:positive])}",
      address: "1 rue Test",
      city: "Paris",
      postal_code: "75001",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    })
    |> Repo.insert!()
  end

  defp insert_lot!(building, attrs) do
    %Lot{}
    |> Lot.changeset(Map.merge(%{type: :parking, building_id: building.id}, attrs))
    |> Repo.insert!()
  end

  defp insert_user! do
    %User{}
    |> User.changeset(%{
      email: "u#{System.unique_integer([:positive])}@test.local",
      role: :coproprietaire
    })
    |> Repo.insert!()
  end

  defp authed(conn, user) do
    {:ok, token, _} = Guardian.sign_in(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /buildings/:b/charging-spots" do
    test "liste les spots flaggés pour un membre", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      spot = insert_lot!(b, %{number: "P01", is_charging_spot: true})
      _normal = insert_lot!(b, %{number: "P02"})

      user = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, user.id, :coproprietaire)

      body =
        conn
        |> authed(user)
        |> get(~p"/api/v1/buildings/#{b.id}/charging-spots")
        |> json_response(200)

      assert [json] = body["data"]
      assert json["id"] == spot.id
      assert json["is_charging_spot"] == true
    end

    test "403 pour un non-membre", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      stranger = insert_user!()

      assert conn
             |> authed(stranger)
             |> get(~p"/api/v1/buildings/#{b.id}/charging-spots")
             |> json_response(403)
    end
  end

  describe "POST /lots/:lot_id/reservations" do
    test "crée une réservation pour un membre", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      spot = insert_lot!(b, %{number: "P01", is_charging_spot: true})

      user = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, user.id, :coproprietaire)

      body =
        conn
        |> authed(user)
        |> post(~p"/api/v1/lots/#{spot.id}/reservations", %{
          reservation: %{
            starts_at: "2026-05-01T18:00:00Z",
            ends_at: "2026-05-01T20:00:00Z"
          }
        })
        |> json_response(201)

      assert body["data"]["status"] == "confirmed"
      assert body["data"]["lot_id"] == spot.id
    end

    test "422 sur recharge > 4h", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      spot = insert_lot!(b, %{number: "P01", is_charging_spot: true})

      user = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, user.id, :coproprietaire)

      body =
        conn
        |> authed(user)
        |> post(~p"/api/v1/lots/#{spot.id}/reservations", %{
          reservation: %{
            starts_at: "2026-05-01T18:00:00Z",
            ends_at: "2026-05-01T23:00:00Z"
          }
        })
        |> json_response(422)

      assert body["errors"]["ends_at"]
    end

    test "403 si l'user n'est pas membre du bâtiment", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      spot = insert_lot!(b, %{number: "P01", is_charging_spot: true})

      stranger = insert_user!()

      assert conn
             |> authed(stranger)
             |> post(~p"/api/v1/lots/#{spot.id}/reservations", %{
               reservation: %{
                 starts_at: "2026-05-01T18:00:00Z",
                 ends_at: "2026-05-01T20:00:00Z"
               }
             })
             |> json_response(403)
    end
  end

  describe "DELETE /reservations/:id" do
    test "annule sa propre réservation", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      spot = insert_lot!(b, %{number: "P01", is_charging_spot: true})

      user = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, user.id, :coproprietaire)

      {:ok, res} =
        Reservations.create_reservation(user.id, spot.id, %{
          "starts_at" => DateTime.from_naive!(~N[2026-05-01 18:00:00], "Etc/UTC"),
          "ends_at" => DateTime.from_naive!(~N[2026-05-01 20:00:00], "Etc/UTC")
        })

      body =
        conn
        |> authed(user)
        |> delete(~p"/api/v1/reservations/#{res.id}")
        |> json_response(200)

      assert body["data"]["status"] == "cancelled"
    end

    test "403 si quelqu'un d'autre essaie d'annuler", %{conn: conn} do
      r = insert_residence!()
      b = insert_building!(r)
      spot = insert_lot!(b, %{number: "P01", is_charging_spot: true})

      owner = insert_user!()
      stranger = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, owner.id, :coproprietaire)
      {:ok, _} = Buildings.add_member(b.id, stranger.id, :coproprietaire)

      {:ok, res} =
        Reservations.create_reservation(owner.id, spot.id, %{
          "starts_at" => DateTime.from_naive!(~N[2026-05-01 18:00:00], "Etc/UTC"),
          "ends_at" => DateTime.from_naive!(~N[2026-05-01 20:00:00], "Etc/UTC")
        })

      assert conn
             |> authed(stranger)
             |> delete(~p"/api/v1/reservations/#{res.id}")
             |> json_response(403)
    end
  end
end
