defmodule KomunBackend.Payments.Payment do
  @moduledoc """
  Trace locale d'un paiement Stripe pour une réservation `:rental`.

  Source de vérité = Stripe (PaymentIntent + Transfer). Cette table sert
  de cache local pour l'affichage rapide ("mes locations", "mes
  encaissements") et de pivot pour les webhooks (lookup par
  `stripe_payment_intent_id`). On ne reçoit jamais d'argent sur le
  compte plateforme : le `transfer_data.destination` envoie directement
  vers le compte connecté du propriétaire, l'`application_fee_amount`
  reste sur la plateforme.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "payments" do
    field :stripe_payment_intent_id, :string
    field :stripe_transfer_id, :string
    field :amount_cents, :integer
    field :commission_cents, :integer, default: 0
    field :currency, :string, default: "eur"
    field :status, Ecto.Enum,
      values: [:pending, :succeeded, :refunded, :failed, :cancelled],
      default: :pending
    field :failure_reason, :string

    belongs_to :reservation, KomunBackend.Reservations.Reservation
    belongs_to :renter, KomunBackend.Accounts.User, foreign_key: :renter_user_id
    belongs_to :owner, KomunBackend.Accounts.User, foreign_key: :owner_user_id

    timestamps(type: :utc_datetime)
  end

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :reservation_id,
      :renter_user_id,
      :owner_user_id,
      :stripe_payment_intent_id,
      :stripe_transfer_id,
      :amount_cents,
      :commission_cents,
      :currency,
      :status,
      :failure_reason
    ])
    |> validate_required([
      :reservation_id,
      :renter_user_id,
      :owner_user_id,
      :amount_cents
    ])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:commission_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:stripe_payment_intent_id, name: :payments_stripe_pi_index)
  end
end
