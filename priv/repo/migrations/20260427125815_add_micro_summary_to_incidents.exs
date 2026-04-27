defmodule KomunBackend.Repo.Migrations.AddMicroSummaryToIncidents do
  use Ecto.Migration

  # Hotfix : `KomunBackend.AI.IncidentRouter.format_incident/1` lit
  # `inc.micro_summary` (cf. PR #48 mergé sur stg le 2026-04-27) mais
  # le champ n'existait ni dans le schéma ni dans la table — chaque
  # email entrant qui passait par le routeur faisait un KeyError.
  #
  # Le résumé court est rempli en aval par `IncidentSummarizer.regenerate/1`
  # (côté IA), donc nullable + pas de backfill à faire ici.
  def change do
    alter table(:incidents) do
      add :micro_summary, :text
    end
  end
end
