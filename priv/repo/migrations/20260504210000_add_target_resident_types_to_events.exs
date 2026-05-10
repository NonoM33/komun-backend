defmodule KomunBackend.Repo.Migrations.AddTargetResidentTypesToEvents do
  use Ecto.Migration

  # Filtrage du public concerné par un événement. Vide = toute la
  # résidence (comportement actuel). Sinon = uniquement les voisins
  # qui matchent au moins l'un des types listés. Buckets supportés :
  #
  #   - "conseil"      : président + membres du conseil syndical
  #   - "proprietaire" : propriétaires occupants (status owner_occupant)
  #   - "bailleur"     : propriétaires bailleurs (status owner_landlord)
  #   - "locataire"    : locataires (status tenant ou role locataire)
  #
  # On filtre les EMAILS et les NOTIFICATIONS auto sur ce critère ; la
  # visibilité côté liste reste ouverte (transparence — un voisin peut
  # voir qu'un atelier "conseil" a lieu, mais il n'est juste pas invité).
  def change do
    alter table(:events) do
      add :target_resident_types, {:array, :string}, null: false, default: []
    end

    # Index GIN pour des futurs filtres « events qui invitent X » sans
    # full-table scan. Coût marginal sur l'écriture, gain certain sur
    # la lecture si on ajoute des dashboards par type.
    execute(
      "CREATE INDEX events_target_resident_types_idx ON events USING GIN (target_resident_types)",
      "DROP INDEX IF EXISTS events_target_resident_types_idx"
    )
  end
end
