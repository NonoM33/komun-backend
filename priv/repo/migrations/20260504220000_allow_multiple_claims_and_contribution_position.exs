defmodule KomunBackend.Repo.Migrations.AllowMultipleClaimsAndContributionPosition do
  use Ecto.Migration

  # Deux changements liés à la refonte UX du potluck :
  #
  # 1. Lever la contrainte d'unicité (contribution_id, user_id) sur les
  #    claims. Un voisin doit pouvoir dire « j'apporte 1 coca zero » ET
  #    « j'apporte 1 coca cherry » sous la même rubrique « Soft » — chaque
  #    libellé sa propre ligne. Avant cette migration, le second clic
  #    « J'en ramène aussi » écrasait silencieusement le premier libellé
  #    (upsert sur la pair unique).
  #
  # 2. Ajouter `position` aux event_contributions pour que l'organisateur
  #    puisse réordonner les rubriques (drag & drop côté UI). Sans champ
  #    explicite on tombe sur l'ordre d'insertion (inserted_at), ce qui
  #    empêche toute personnalisation.
  def change do
    drop_if_exists unique_index(:event_contribution_claims, [:contribution_id, :user_id])
    create index(:event_contribution_claims, [:contribution_id, :user_id])

    alter table(:event_contributions) do
      add :position, :integer, null: false, default: 0
    end

    create index(:event_contributions, [:event_id, :position])

    # Backfill positions : ordre actuel = inserted_at. Les events
    # existants gardent ainsi visuellement le même ordre après migration.
    execute(
      """
      UPDATE event_contributions ec
      SET position = sub.rn
      FROM (
        SELECT id, ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY inserted_at) AS rn
        FROM event_contributions
      ) sub
      WHERE ec.id = sub.id
      """,
      ""
    )
  end
end
