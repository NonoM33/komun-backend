defmodule KomunBackend.Repo.Migrations.AddMicroSummaryToIncidents do
  use Ecto.Migration

  # micro_summary : 1 phrase ultra-courte (≤ 160 chars) générée par Groq.
  # Affichée dans la vue liste/Kanban des incidents quand on veut le
  # résumé en un coup d'œil sans étirer les cards. La description longue
  # (markdown) reste utilisée sur la fiche détail.
  def change do
    alter table(:incidents) do
      add :micro_summary, :string, size: 200
    end
  end
end
