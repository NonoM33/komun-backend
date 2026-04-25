defmodule KomunBackend.Repo.Migrations.CreateBattles do
  use Ecto.Migration

  def change do
    create table(:battles, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :title, :string, null: false
      add :description, :text

      # running   → un round est ouvert ou en attente de tally
      # finished  → un gagnant a été désigné, winning_option_label peuplé
      # cancelled → arrêt anticipé (pas implémenté V1, gardé pour la suite)
      add :status, :string, null: false, default: "running"

      # Configuration de la cadence — paramétrable par battle pour qu'on
      # puisse plus tard avoir des battles "express" (1 jour par round)
      # ou "lente" (7 jours pour les sujets engageants).
      add :round_duration_days, :integer, null: false, default: 3

      # max_rounds inclut le round 1. À 2 (default), on a "5 → top2 → 1".
      # À 3, on aurait "9 → top4 → top2 → 1" si on veut.
      add :max_rounds, :integer, null: false, default: 2

      add :current_round, :integer, null: false, default: 1

      # Quorum non bloquant en V1 — sert juste à afficher "décision
      # représentative ?" dans la UI. 0 = pas de seuil affiché.
      add :quorum_pct, :integer, null: false, default: 30

      # Une fois la battle finished, on dénormalise le label du gagnant
      # ici pour qu'on n'ait pas à charger les VoteOption du round final
      # (qui peuvent avoir été supprimées si on nettoie un jour).
      add :winning_option_label, :string

      timestamps(type: :utc_datetime)
    end

    create index(:battles, [:building_id])
    create index(:battles, [:building_id, :status])

    # On chaîne les Vote au Battle parent. round_number = 1 pour le
    # premier vote, 2 pour le run-off, etc. Les Vote restent autonomes
    # (peuvent exister sans battle) — ces colonnes sont nullables.
    alter table(:votes) do
      add :battle_id, references(:battles, type: :binary_id, on_delete: :nilify_all)
      add :round_number, :integer
    end

    create index(:votes, [:battle_id, :round_number])
  end
end
