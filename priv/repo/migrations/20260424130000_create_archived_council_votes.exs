defmodule KomunBackend.Repo.Migrations.CreateArchivedCouncilVotes do
  use Ecto.Migration

  @moduledoc """
  Table d'archive des votes du conseil syndical effectués sur l'ancienne
  stack Ruby on Rails (table `council_votes`). On ne porte pas la
  logique de vote — c'est read-only, juste pour préserver l'historique
  (ex. élections des membres du CS) au cas où la DA refont un vote ou
  ont besoin de consulter les résultats passés.

  On utilise un JSON pour les options pour ne pas avoir à maintenir
  trois tables liées (votes, options, casts). Les données sources
  viennent d'un dump JSON côté admin.
  """

  def change do
    create table(:archived_council_votes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Identifiant d'origine côté Rails pour idempotence de l'import.
      add :legacy_id, :string, null: false

      # Résidence qui a tenu le vote — nullable car le Rails travaillait
      # par "Organization" et on pourrait ne pas savoir mapper à 100%.
      add :residence_id,
          references(:residences, type: :binary_id, on_delete: :nilify_all)

      add :title, :string, null: false
      add :description, :text
      add :vote_type, :string
      add :status, :string
      add :anonymous, :boolean, default: false

      # Snapshot des options avec leur décompte final.
      # Forme : [%{"text" => "Option A", "votes_count" => 12, "weighted_votes" => 12}]
      add :options, {:array, :map}, default: []

      add :total_votes, :integer, default: 0
      add :winning_option_text, :string

      add :starts_at, :utc_datetime
      add :ends_at, :utc_datetime
      add :closed_at, :utc_datetime

      # Date de création originale (préservée pour afficher "Vote du 12 mai 2024").
      add :legacy_created_at, :utc_datetime, null: false

      # Date d'import dans cette table Elixir.
      timestamps(type: :utc_datetime)
    end

    create unique_index(:archived_council_votes, [:legacy_id])
    create index(:archived_council_votes, [:residence_id])
    create index(:archived_council_votes, [:legacy_created_at])
  end
end
