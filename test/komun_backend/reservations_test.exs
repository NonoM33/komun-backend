defmodule KomunBackend.ReservationsTest do
  @moduledoc """
  Tests TDD du contexte Réservations (places de recharge V1).

  Couvre :
  - Création nominale (lot charging spot, user membre, créneau libre)
  - Anti-overlap Postgres (constraint EXCLUDE) = pas de double réservation
  - Limite charging max 4h
  - Refus si user pas membre du bâtiment
  - Cancel par le propriétaire / par admin building / refus pour autres
  - Liste des spots flaggés / réservations par lot / mes upcoming
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Repo, Reservations, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.{Building, Lot}
  alias KomunBackend.Residences.Residence
  alias KomunBackend.Reservations.Reservation

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

  defp setup_charging_world do
    r = insert_residence!()
    b = insert_building!(r)
    spot = insert_lot!(b, %{number: "P01", is_charging_spot: true})
    member = insert_user!()
    {:ok, _} = Buildings.add_member(b.id, member.id, :coproprietaire)
    %{building: b, spot: spot, member: member}
  end

  defp ts(naive_iso) do
    {:ok, dt, _} = DateTime.from_iso8601(naive_iso)
    dt |> DateTime.truncate(:second)
  end

  describe "list_charging_spots/1" do
    test "ne retourne que les lots flaggés is_charging_spot du bâtiment" do
      r = insert_residence!()
      b = insert_building!(r)

      spot1 = insert_lot!(b, %{number: "P01", is_charging_spot: true})
      _spot2_other_building = insert_lot!(insert_building!(r), %{number: "P01", is_charging_spot: true})
      _normal_parking = insert_lot!(b, %{number: "P02"})

      result = Reservations.list_charging_spots(b.id)
      assert Enum.map(result, & &1.id) == [spot1.id]
    end
  end

  describe "create_reservation/3" do
    test "crée une réservation confirmée pour un membre actif" do
      %{spot: spot, member: member} = setup_charging_world()

      assert {:ok, %Reservation{} = res} =
               Reservations.create_reservation(member.id, spot.id, %{
                 "starts_at" => ts("2026-05-01T18:00:00Z"),
                 "ends_at" => ts("2026-05-01T20:00:00Z")
               })

      assert res.status == :confirmed
      assert res.kind == :charging
      assert res.user_id == member.id
      assert res.lot_id == spot.id
      assert res.building_id == spot.building_id
    end

    test "refuse une réservation chevauchante (Postgres EXCLUDE)" do
      %{spot: spot, member: m1} = setup_charging_world()
      m2 = insert_user!()
      {:ok, _} = Buildings.add_member(spot.building_id, m2.id, :coproprietaire)

      {:ok, _} =
        Reservations.create_reservation(m1.id, spot.id, %{
          "starts_at" => ts("2026-05-01T18:00:00Z"),
          "ends_at" => ts("2026-05-01T20:00:00Z")
        })

      # Chevauchement partiel
      assert {:error, %Ecto.Changeset{} = cs} =
               Reservations.create_reservation(m2.id, spot.id, %{
                 "starts_at" => ts("2026-05-01T19:00:00Z"),
                 "ends_at" => ts("2026-05-01T21:00:00Z")
               })

      assert errors_on(cs)[:starts_at] != nil
    end

    test "autorise deux réservations adjacentes (fin = début, pas de chevauchement)" do
      %{spot: spot, member: m1} = setup_charging_world()
      m2 = insert_user!()
      {:ok, _} = Buildings.add_member(spot.building_id, m2.id, :coproprietaire)

      assert {:ok, _} =
               Reservations.create_reservation(m1.id, spot.id, %{
                 "starts_at" => ts("2026-05-01T18:00:00Z"),
                 "ends_at" => ts("2026-05-01T20:00:00Z")
               })

      assert {:ok, _} =
               Reservations.create_reservation(m2.id, spot.id, %{
                 "starts_at" => ts("2026-05-01T20:00:00Z"),
                 "ends_at" => ts("2026-05-01T22:00:00Z")
               })
    end

    test "refuse les recharges > 4h" do
      %{spot: spot, member: m} = setup_charging_world()

      assert {:error, cs} =
               Reservations.create_reservation(m.id, spot.id, %{
                 "starts_at" => ts("2026-05-01T18:00:00Z"),
                 "ends_at" => ts("2026-05-01T23:00:00Z")
               })

      assert "une recharge dure au maximum 4h" in errors_on(cs).ends_at
    end

    test "refuse fin <= début" do
      %{spot: spot, member: m} = setup_charging_world()

      assert {:error, cs} =
               Reservations.create_reservation(m.id, spot.id, %{
                 "starts_at" => ts("2026-05-01T20:00:00Z"),
                 "ends_at" => ts("2026-05-01T18:00:00Z")
               })

      assert errors_on(cs).ends_at != []
    end

    test "refuse {:error, :not_member} pour un user pas membre du bâtiment" do
      %{spot: spot} = setup_charging_world()
      stranger = insert_user!()

      assert {:error, :not_member} =
               Reservations.create_reservation(stranger.id, spot.id, %{
                 "starts_at" => ts("2026-05-01T18:00:00Z"),
                 "ends_at" => ts("2026-05-01T20:00:00Z")
               })
    end

    test "refuse {:error, :lot_not_found} si le lot n'existe pas" do
      member = insert_user!()

      assert {:error, :lot_not_found} =
               Reservations.create_reservation(member.id, Ecto.UUID.generate(), %{
                 "starts_at" => ts("2026-05-01T18:00:00Z"),
                 "ends_at" => ts("2026-05-01T20:00:00Z")
               })
    end
  end

  describe "cancel_reservation/2" do
    test "le propriétaire de la réservation peut l'annuler" do
      %{spot: spot, member: m} = setup_charging_world()

      {:ok, r} =
        Reservations.create_reservation(m.id, spot.id, %{
          "starts_at" => ts("2026-05-01T18:00:00Z"),
          "ends_at" => ts("2026-05-01T20:00:00Z")
        })

      assert {:ok, cancelled} = Reservations.cancel_reservation(r.id, m.id)
      assert cancelled.status == :cancelled
    end

    test "un autre membre normal ne peut PAS annuler" do
      %{spot: spot, member: m} = setup_charging_world()
      stranger = insert_user!()
      {:ok, _} = Buildings.add_member(spot.building_id, stranger.id, :coproprietaire)

      {:ok, r} =
        Reservations.create_reservation(m.id, spot.id, %{
          "starts_at" => ts("2026-05-01T18:00:00Z"),
          "ends_at" => ts("2026-05-01T20:00:00Z")
        })

      assert {:error, :forbidden} = Reservations.cancel_reservation(r.id, stranger.id)
    end

    test "un membre du conseil syndical peut annuler n'importe quelle résa du bâtiment" do
      %{spot: spot, member: m} = setup_charging_world()
      cs = insert_user!()
      {:ok, _} = Buildings.add_member(spot.building_id, cs.id, :president_cs)

      {:ok, r} =
        Reservations.create_reservation(m.id, spot.id, %{
          "starts_at" => ts("2026-05-01T18:00:00Z"),
          "ends_at" => ts("2026-05-01T20:00:00Z")
        })

      assert {:ok, _} = Reservations.cancel_reservation(r.id, cs.id)
    end

    test "après cancel, le créneau redevient disponible" do
      %{spot: spot, member: m1} = setup_charging_world()
      m2 = insert_user!()
      {:ok, _} = Buildings.add_member(spot.building_id, m2.id, :coproprietaire)

      {:ok, r1} =
        Reservations.create_reservation(m1.id, spot.id, %{
          "starts_at" => ts("2026-05-01T18:00:00Z"),
          "ends_at" => ts("2026-05-01T20:00:00Z")
        })

      {:ok, _} = Reservations.cancel_reservation(r1.id, m1.id)

      # Le même créneau doit redevenir réservable
      assert {:ok, _} =
               Reservations.create_reservation(m2.id, spot.id, %{
                 "starts_at" => ts("2026-05-01T18:00:00Z"),
                 "ends_at" => ts("2026-05-01T20:00:00Z")
               })
    end
  end

  describe "list_reservations_for_lot/3" do
    test "retourne les confirmed dans la fenêtre, exclut les cancelled" do
      %{spot: spot, member: m1} = setup_charging_world()
      m2 = insert_user!()
      {:ok, _} = Buildings.add_member(spot.building_id, m2.id, :coproprietaire)

      {:ok, _r1} =
        Reservations.create_reservation(m1.id, spot.id, %{
          "starts_at" => ts("2026-05-01T18:00:00Z"),
          "ends_at" => ts("2026-05-01T20:00:00Z")
        })

      {:ok, r2} =
        Reservations.create_reservation(m2.id, spot.id, %{
          "starts_at" => ts("2026-05-02T18:00:00Z"),
          "ends_at" => ts("2026-05-02T20:00:00Z")
        })

      {:ok, _} = Reservations.cancel_reservation(r2.id, m2.id)

      # Fenêtre couvre les deux dates
      list =
        Reservations.list_reservations_for_lot(
          spot.id,
          ts("2026-05-01T00:00:00Z"),
          ts("2026-05-03T00:00:00Z")
        )

      # Le cancelled (r2) est filtré
      assert length(list) == 1
    end
  end
end
