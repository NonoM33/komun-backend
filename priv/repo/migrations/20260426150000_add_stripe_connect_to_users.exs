defmodule KomunBackend.Repo.Migrations.AddStripeConnectToUsers do
  use Ecto.Migration

  # Stripe Connect Express — chaque copro propriétaire qui souhaite louer
  # sa place reçoit son propre compte Stripe (créé via /me/stripe-connect/
  # onboarding). L'argent va directement chez lui ; la plateforme prélève
  # une `application_fee` (commission). Évite l'écueil "intermédiation
  # bancaire sans agrément" + préserve le statut micro-entreprise du
  # propriétaire de la plateforme (seule la commission compte dans le CA).
  def change do
    alter table(:users) do
      add :stripe_connect_account_id, :string
      add :stripe_connect_onboarded_at, :utc_datetime
      add :stripe_connect_status, :string, default: "none"
    end

    create unique_index(:users, [:stripe_connect_account_id],
             where: "stripe_connect_account_id IS NOT NULL",
             name: :users_stripe_connect_account_id_index)
  end
end
