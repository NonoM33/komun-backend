defmodule KomunBackend.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :slug, :string, null: false
      add :type, :string, null: false, default: "autonomous"
      add :siret, :string
      add :email, :string
      add :phone, :string
      add :logo_url, :string
      add :address, :map
      add :subscription_plan, :string, null: false, default: "free"
      add :subscription_expires_at, :utc_datetime
      add :stripe_customer_id, :string
      add :stripe_subscription_id, :string
      add :settings, :map, default: fragment("'{}'::jsonb")
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:slug])
    create index(:organizations, [:type])
    create index(:organizations, [:is_active])
  end
end
