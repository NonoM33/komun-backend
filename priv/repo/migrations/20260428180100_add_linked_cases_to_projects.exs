defmodule KomunBackend.Repo.Migrations.AddLinkedCasesToProjects do
  use Ecto.Migration

  @moduledoc """
  Liaison projet (devis) ↔ dossier (incident / doléance / diligence).

  Permet, depuis la fiche d'un dossier, de cliquer « Demander un devis »
  qui crée un projet pré-rempli et déjà rattaché. Permet aussi à un
  projet existant d'être rattaché a posteriori à un dossier.

  Les 3 colonnes sont nullable + ON DELETE SET NULL : si le dossier
  source est supprimé, le projet (et ses devis) doivent survivre, on
  perd juste le rattachement. Pas de contrainte « au plus un lien à
  la fois » côté DB — la validation se fait dans le changeset, plus
  simple à gérer côté UI (sinon on est obligé de stripper deux champs
  côté front à chaque PATCH).
  """

  def change do
    alter table(:projects) do
      add :linked_incident_id,
          references(:incidents, type: :binary_id, on_delete: :nilify_all)

      add :linked_doleance_id,
          references(:doleances, type: :binary_id, on_delete: :nilify_all)

      add :linked_diligence_id,
          references(:diligences, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:projects, [:linked_incident_id])
    create index(:projects, [:linked_doleance_id])
    create index(:projects, [:linked_diligence_id])
  end
end
