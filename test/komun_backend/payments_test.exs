defmodule KomunBackend.PaymentsTest do
  @moduledoc """
  Tests TDD du module Payments — calcul du montant, commission, et
  intégration Stripe (via le mock adapter, pas d'appel réseau réel).
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Payments, Repo, Reservations, Residences, StripeConnect}
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

  defp insert_user! do
    %User{}
    |> User.changeset(%{
      email: "u#{System.unique_integer([:positive])}@test.local",
      role: :coproprietaire
    })
    |> Repo.insert!()
  end

  defp insert_rentable_lot!(building, owner, attrs \\ %{}) do
    defaults = %{
      number: "P#{System.unique_integer([:positive])}",
      type: :parking,
      is_rentable: true,
      rental_price_per_hour_cents: 200,
      rental_price_per_month_cents: 80_000,
      building_id: building.id,
      owner_id: owner.id
    }

    %Lot{}
    |> Lot.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp setup_rental_world(opts \\ []) do
    r = insert_residence!()
    b = insert_building!(r)
    owner = insert_user!()
    renter = insert_user!()

    {:ok, _} = Buildings.add_member(b.id, owner.id, :coproprietaire)
    {:ok, _} = Buildings.add_member(b.id, renter.id, :coproprietaire)

    # Onboard the owner via the mock Stripe adapter
    onboard? = Keyword.get(opts, :owner_onboarded, true)

    owner =
      if onboard? do
        {:ok, %{user: u}} =
          StripeConnect.start_onboarding(owner, "https://komun.app/return", "https://komun.app/refresh")

        {:ok, u} = StripeConnect.refresh_status(u)
        u
      else
        owner
      end

    lot = insert_rentable_lot!(b, owner)

    %{building: b, owner: owner, renter: renter, lot: lot}
  end

  defp ts(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    DateTime.truncate(dt, :second)
  end

  describe "amount_for_rental/2" do
    test "calcule en horaire pour < 1 mois" do
      lot = %Lot{rental_price_per_hour_cents: 200, rental_price_per_month_cents: 80_000}
      res = %Reservation{starts_at: ts("2026-05-01T10:00:00Z"), ends_at: ts("2026-05-01T13:00:00Z")}

      assert {:ok, 600} = Payments.amount_for_rental(res, lot)
    end

    test "passe en mensuel proratisé pour > 30 jours" do
      lot = %Lot{rental_price_per_hour_cents: 200, rental_price_per_month_cents: 80_000}

      res = %Reservation{
        starts_at: ts("2026-05-01T00:00:00Z"),
        ends_at: ts("2026-08-01T00:00:00Z")
      }

      assert {:ok, cents} = Payments.amount_for_rental(res, lot)
      # ~3 mois → ~240 000 ± 5%
      assert cents > 230_000
      assert cents < 250_000
    end

    test "renvoie :no_price si aucun tarif n'est configuré" do
      lot = %Lot{rental_price_per_hour_cents: nil, rental_price_per_month_cents: nil}
      res = %Reservation{starts_at: ts("2026-05-01T10:00:00Z"), ends_at: ts("2026-05-01T13:00:00Z")}

      assert :no_price = Payments.amount_for_rental(res, lot)
    end
  end

  describe "create_payment_for_reservation/1" do
    test "crée un PaymentIntent et insère un payment :pending" do
      %{owner: owner, renter: renter, lot: lot} = setup_rental_world()

      {:ok, res} =
        Reservations.create_reservation(renter.id, lot.id, %{
          "kind" => "rental",
          "starts_at" => ts("2026-06-01T10:00:00Z"),
          "ends_at" => ts("2026-06-01T13:00:00Z")
        })

      assert {:ok, payment, intent} = Payments.create_payment_for_reservation(res)

      assert payment.status == :pending
      assert payment.amount_cents == 600
      assert payment.commission_cents == 60  # 10% par défaut
      assert payment.owner_user_id == owner.id
      assert payment.renter_user_id == renter.id
      assert intent["client_secret"]
      assert intent["transfer_data"][:destination] == owner.stripe_connect_account_id
    end

    test "refuse {:error, :owner_not_onboarded} si l'owner n'a pas onboardé Stripe" do
      %{renter: renter, lot: lot} = setup_rental_world(owner_onboarded: false)

      {:ok, res} =
        Reservations.create_reservation(renter.id, lot.id, %{
          "kind" => "rental",
          "starts_at" => ts("2026-06-01T10:00:00Z"),
          "ends_at" => ts("2026-06-01T13:00:00Z")
        })

      assert {:error, :owner_not_onboarded} =
               Payments.create_payment_for_reservation(res)
    end
  end

  describe "mark_succeeded/2 et mark_failed/2" do
    test "transitionne pending → succeeded (idempotent)" do
      %{renter: renter, lot: lot} = setup_rental_world()

      {:ok, res} =
        Reservations.create_reservation(renter.id, lot.id, %{
          "kind" => "rental",
          "starts_at" => ts("2026-06-01T10:00:00Z"),
          "ends_at" => ts("2026-06-01T13:00:00Z")
        })

      {:ok, _, intent} = Payments.create_payment_for_reservation(res)

      assert {:ok, p} = Payments.mark_succeeded(intent["id"])
      assert p.status == :succeeded

      # Idempotent : second appel ne plante pas, retourne le même payment
      assert {:ok, p2} = Payments.mark_succeeded(intent["id"])
      assert p2.id == p.id
      assert p2.status == :succeeded
    end

    test "mark_failed enregistre la raison" do
      %{renter: renter, lot: lot} = setup_rental_world()

      {:ok, res} =
        Reservations.create_reservation(renter.id, lot.id, %{
          "kind" => "rental",
          "starts_at" => ts("2026-06-01T10:00:00Z"),
          "ends_at" => ts("2026-06-01T13:00:00Z")
        })

      {:ok, _, intent} = Payments.create_payment_for_reservation(res)

      assert {:ok, p} = Payments.mark_failed(intent["id"], "card_declined")
      assert p.status == :failed
      assert p.failure_reason == "card_declined"
    end
  end

  describe "maybe_refund_for_cancel/1" do
    test "rembourse 100% si annulation > 2h avant le début" do
      %{renter: renter, lot: lot} = setup_rental_world()

      future = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)

      {:ok, res} =
        Reservations.create_reservation(renter.id, lot.id, %{
          "kind" => "rental",
          "starts_at" => future,
          "ends_at" => DateTime.add(future, 3 * 3600, :second)
        })

      {:ok, _, intent} = Payments.create_payment_for_reservation(res)
      {:ok, _} = Payments.mark_succeeded(intent["id"])

      assert {:ok, refunded} = Payments.maybe_refund_for_cancel(res)
      assert refunded.status == :refunded
    end

    test "ne rembourse rien si annulation < 2h avant le début" do
      %{renter: renter, lot: lot} = setup_rental_world()

      soon = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      {:ok, res} =
        Reservations.create_reservation(renter.id, lot.id, %{
          "kind" => "rental",
          "starts_at" => soon,
          "ends_at" => DateTime.add(soon, 3 * 3600, :second)
        })

      {:ok, _, intent} = Payments.create_payment_for_reservation(res)
      {:ok, _} = Payments.mark_succeeded(intent["id"])

      assert {:ok, :no_refund} = Payments.maybe_refund_for_cancel(res)
    end
  end

  describe "list_for_renter/1 et list_for_owner/1" do
    test "sépare bien les paiements selon le rôle" do
      %{owner: owner, renter: renter, lot: lot} = setup_rental_world()

      {:ok, res} =
        Reservations.create_reservation(renter.id, lot.id, %{
          "kind" => "rental",
          "starts_at" => ts("2026-06-01T10:00:00Z"),
          "ends_at" => ts("2026-06-01T13:00:00Z")
        })

      {:ok, _, _} = Payments.create_payment_for_reservation(res)

      assert [_] = Payments.list_for_renter(renter.id)
      assert [] = Payments.list_for_renter(owner.id)
      assert [_] = Payments.list_for_owner(owner.id)
      assert [] = Payments.list_for_owner(renter.id)
    end
  end
end
