defmodule KomunBackend.Repo.Migrations.AddIsInformationalToEvents do
  use Ecto.Migration

  # Distingue un événement « informatif » (annonce datée : nettoyage des
  # parkings, coupure d'eau, passage d'un technicien…) d'un événement
  # convivial (fête des voisins, atelier). Un événement informatif n'a ni
  # inscription (« Je participe »), ni apports (« Qui ramène quoi »), ni
  # accompagnants : c'est une simple fiche info. Le frontend masque ces
  # sections quand le flag est vrai. Défaut false = comportement actuel
  # inchangé pour tous les events existants.
  def change do
    alter table(:events) do
      add :is_informational, :boolean, null: false, default: false
    end
  end
end
