defmodule KomunBackend.Repo.Migrations.CreatePayments do
  use Ecto.Migration

  # Trace de toute opération financière liée à une réservation `:rental`.
  # On ne touche jamais aux montants côté code une fois enregistrés —
  # la source de vérité reste Stripe, on garde une copie locale pour
  # affichage rapide et reconciliation comptable.
  def change do
    create table(:payments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reservation_id, references(:reservations, type: :binary_id, on_delete: :restrict),
          null: false

      add :renter_user_id, references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      add :owner_user_id, references(:users, type: :binary_id, on_delete: :restrict),
          null: false

      add :stripe_payment_intent_id, :string
      add :stripe_transfer_id, :string

      add :amount_cents, :integer, null: false
      add :commission_cents, :integer, null: false, default: 0
      add :currency, :string, null: false, default: "eur"
      add :status, :string, null: false, default: "pending"

      add :failure_reason, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payments, [:stripe_payment_intent_id],
             where: "stripe_payment_intent_id IS NOT NULL",
             name: :payments_stripe_pi_index)

    create index(:payments, [:reservation_id])
    create index(:payments, [:renter_user_id])
    create index(:payments, [:owner_user_id])
    create index(:payments, [:status])
  end
end
