defmodule KomunBackend.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :email, :string, null: false
      add :role, :string, null: false, default: "coproprietaire"
      add :first_name, :string
      add :last_name, :string
      add :phone, :string
      add :avatar_url, :string
      add :locale, :string, default: "fr"
      add :push_tokens, {:array, :string}, default: []
      add :last_sign_in_at, :utc_datetime
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create index(:users, [:organization_id])
    create index(:users, [:role])
  end
end
