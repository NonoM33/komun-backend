defmodule KomunBackend.Payments do
  @moduledoc """
  Création des PaymentIntents Stripe pour la location payante de places
  (réservations `kind: :rental`).

  Architecture :
  - Le locataire (`renter`) déclenche le paiement.
  - Le propriétaire (`owner`) doit avoir un compte Stripe Connect
    `:verified`. Sinon, on refuse `{:error, :owner_not_onboarded}`.
  - Stripe crée un PaymentIntent avec `transfer_data.destination` = le
    compte du proprio → l'argent va DIRECTEMENT chez lui.
  - `application_fee_amount` = commission plateforme (% configurable).

  Commission par défaut = 10 %, override via :

      config :komun_backend, :platform_fee_percent, 8

  Politique de remboursement (cancel d'une réservation rental) :
  - Annulé > 2h avant `starts_at` → refund 100 %
  - Annulé < 2h avant ou après `starts_at` → pas de refund
  Le seuil est configurable via `:rental_refund_grace_hours`.
  """

  import Ecto.Query

  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Lot
  alias KomunBackend.Payments.Payment
  alias KomunBackend.Repo
  alias KomunBackend.Reservations.Reservation
  alias KomunBackend.StripeApi

  @default_platform_fee_percent 10
  @default_refund_grace_hours 2

  @doc """
  Calcule le montant total d'une réservation `:rental` selon son type :
  - Si la réservation tient en N heures pleines → `N * price_per_hour`.
  - Si > 30 jours → tarif mensuel proratisé.
  - Sinon → toujours horaire.
  Retourne `:no_price` si le lot n'a pas de prix configuré.
  """
  def amount_for_rental(%Reservation{} = res, %Lot{} = lot) do
    duration_hours =
      DateTime.diff(res.ends_at, res.starts_at, :second) / 3600.0

    cond do
      duration_hours <= 0 ->
        :no_price

      duration_hours >= 24 * 30 && lot.rental_price_per_month_cents ->
        # Mensuel proratisé : N mois calendaires arrondis à 30 jours.
        months = duration_hours / (24 * 30)
        cents = round(months * lot.rental_price_per_month_cents)
        if cents > 0, do: {:ok, cents}, else: :no_price

      lot.rental_price_per_hour_cents ->
        cents = round(duration_hours * lot.rental_price_per_hour_cents)
        if cents > 0, do: {:ok, cents}, else: :no_price

      true ->
        :no_price
    end
  end

  @doc """
  Crée le PaymentIntent Stripe + insère la ligne `payments` locale (status
  `:pending`). Le frontend confirme le paiement via Stripe Elements en
  utilisant le `client_secret` retourné.

  Erreurs possibles :
  - `:owner_not_onboarded` — le proprio n'a pas finalisé Stripe Connect.
  - `:lot_not_rentable` — le lot n'a pas `is_rentable: true`.
  - `:no_price` — pas de prix configuré.
  - `{:stripe, error}` — erreur Stripe (mauvaise clé, validation, …).
  """
  def create_payment_for_reservation(%Reservation{kind: :rental} = res) do
    res = Repo.preload(res, lot: [:owner], user: [])

    with %Lot{is_rentable: true, owner: %User{} = owner} = lot <- check_lot(res.lot),
         :ok <- check_owner_onboarded(owner),
         {:ok, amount_cents} <- check_amount(res, lot),
         commission_cents = compute_commission(amount_cents),
         {:ok, intent} <-
           StripeApi.create_payment_intent(%{
             amount: amount_cents,
             currency: "eur",
             application_fee_amount: commission_cents,
             transfer_data: %{destination: owner.stripe_connect_account_id},
             metadata: %{
               reservation_id: res.id,
               renter_user_id: res.user_id,
               owner_user_id: owner.id,
               lot_id: lot.id
             }
           }),
         {:ok, payment} <-
           insert_payment(res, owner, intent, amount_cents, commission_cents) do
      {:ok, payment, intent}
    else
      {:error, _} = err -> err
      :no_price -> {:error, :no_price}
      :owner_not_onboarded -> {:error, :owner_not_onboarded}
      :lot_not_rentable -> {:error, :lot_not_rentable}
      _ -> {:error, :unknown}
    end
  end

  def create_payment_for_reservation(_), do: {:error, :not_a_rental}

  defp check_lot(%Lot{is_rentable: true, owner: %User{stripe_connect_account_id: id}} = lot)
       when is_binary(id),
       do: lot

  defp check_lot(%Lot{is_rentable: false}), do: :lot_not_rentable
  defp check_lot(_), do: :owner_not_onboarded

  defp check_owner_onboarded(%User{stripe_connect_status: :verified, stripe_connect_account_id: id})
       when is_binary(id),
       do: :ok

  defp check_owner_onboarded(_), do: :owner_not_onboarded

  defp check_amount(res, lot) do
    case amount_for_rental(res, lot) do
      {:ok, cents} -> {:ok, cents}
      :no_price -> :no_price
    end
  end

  defp compute_commission(amount_cents) do
    pct = Application.get_env(:komun_backend, :platform_fee_percent, @default_platform_fee_percent)
    div(amount_cents * pct, 100)
  end

  defp insert_payment(res, owner, intent, amount_cents, commission_cents) do
    %Payment{}
    |> Payment.changeset(%{
      reservation_id: res.id,
      renter_user_id: res.user_id,
      owner_user_id: owner.id,
      stripe_payment_intent_id: intent["id"],
      amount_cents: amount_cents,
      commission_cents: commission_cents,
      currency: intent["currency"] || "eur",
      status: :pending
    })
    |> Repo.insert()
  end

  @doc """
  Marque un payment comme `:succeeded` après réception du webhook Stripe
  `payment_intent.succeeded`. Idempotent : si déjà succeeded, no-op.
  """
  def mark_succeeded(stripe_payment_intent_id, transfer_id \\ nil) do
    case Repo.get_by(Payment, stripe_payment_intent_id: stripe_payment_intent_id) do
      nil -> {:error, :not_found}
      %Payment{status: :succeeded} = p -> {:ok, p}
      %Payment{} = p ->
        p
        |> Payment.changeset(%{status: :succeeded, stripe_transfer_id: transfer_id})
        |> Repo.update()
    end
  end

  @doc "Marque un payment comme `:failed` (webhook payment_intent.payment_failed)."
  def mark_failed(stripe_payment_intent_id, reason) do
    case Repo.get_by(Payment, stripe_payment_intent_id: stripe_payment_intent_id) do
      nil -> {:error, :not_found}
      %Payment{} = p ->
        p
        |> Payment.changeset(%{status: :failed, failure_reason: reason})
        |> Repo.update()
    end
  end

  @doc """
  Refund automatique selon politique : 100% si annulation > grace_hours
  avant `starts_at`, sinon rien. Retourne `{:ok, :no_refund}` ou
  `{:ok, payment}` ou `{:error, …}`.
  """
  def maybe_refund_for_cancel(%Reservation{kind: :rental} = res) do
    grace =
      Application.get_env(
        :komun_backend,
        :rental_refund_grace_hours,
        @default_refund_grace_hours
      )

    threshold = DateTime.add(res.starts_at, -grace * 3600, :second)
    now = DateTime.utc_now()

    if DateTime.compare(now, threshold) == :lt do
      do_full_refund(res)
    else
      {:ok, :no_refund}
    end
  end

  def maybe_refund_for_cancel(_), do: {:ok, :no_refund}

  defp do_full_refund(%Reservation{} = res) do
    case Repo.get_by(Payment, reservation_id: res.id, status: :succeeded) do
      nil ->
        {:ok, :no_refund}

      %Payment{stripe_payment_intent_id: pi_id} = payment ->
        case StripeApi.refund_payment_intent(pi_id, %{amount: payment.amount_cents}) do
          {:ok, _} ->
            payment
            |> Payment.changeset(%{status: :refunded})
            |> Repo.update()

          {:error, _} = err ->
            err
        end
    end
  end

  @doc "Mes paiements en tant que locataire (locations à venir / passées)."
  def list_for_renter(user_id) do
    from(p in Payment,
      where: p.renter_user_id == ^user_id,
      order_by: [desc: p.inserted_at],
      preload: [reservation: :lot]
    )
    |> Repo.all()
  end

  @doc "Mes encaissements en tant que propriétaire."
  def list_for_owner(user_id) do
    from(p in Payment,
      where: p.owner_user_id == ^user_id,
      order_by: [desc: p.inserted_at],
      preload: [reservation: :lot]
    )
    |> Repo.all()
  end
end
