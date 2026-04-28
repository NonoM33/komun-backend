defmodule KomunBackend.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  # Personal Access Tokens — pour permettre aux membres du conseil
  # syndical (et au syndic) de scripter / piloter l'app via l'API
  # sans utiliser le flow magic-link interactif.
  #
  # Le token en clair (`kmn_pat_<random>`) n'est JAMAIS stocké : on
  # garde uniquement son hash SHA-256 (`token_hash`) plus un préfixe
  # court (`token_prefix`) qu'on peut afficher dans la liste pour
  # que l'utilisateur retrouve le token sans en révéler la valeur.
  def change do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :token_prefix, :string, null: false

      add :last_used_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:user_id])
  end
end
