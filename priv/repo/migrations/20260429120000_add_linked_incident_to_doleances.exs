defmodule KomunBackend.Repo.Migrations.AddLinkedIncidentToDoleances do
  use Ecto.Migration

  # Permet de tracer une doléance comme l'évolution d'un incident
  # ("dégât signalé → finalement passé en garantie / décennale →
  # devenu une doléance collective"). FK optionnelle (la majorité des
  # doléances continuent de naître ex nihilo) avec ON DELETE NILIFY :
  # si l'incident d'origine est supprimé, on garde la doléance mais on
  # perd juste le rétro-lien — on ne casse pas un dossier en cours.
  def change do
    alter table(:doleances) do
      add :linked_incident_id,
          references(:incidents, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:doleances, [:linked_incident_id])
  end
end
