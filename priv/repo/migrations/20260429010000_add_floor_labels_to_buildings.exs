defmodule KomunBackend.Repo.Migrations.AddFloorLabelsToBuildings do
  use Ecto.Migration

  # Étiquettes d'étage personnalisées par bâtiment.
  #
  # Sans override, le frontend calcule l'étiquette depuis l'entier
  # `floor` (0 → "Rez-de-chaussée", 1 → "1er étage", ...). Mais la
  # convention varie d'un bâtiment à l'autre — certains immeubles
  # appellent leur RDC "Niveau 1" ou "Boutique", d'autres ont une
  # mezzanine, etc. Ce champ stocke un override par étage :
  #
  #   %{"0" => "Rez-de-chaussée commercial", "1" => "Mezzanine"}
  #
  # Les clés sont des strings (Ecto :map serialise comme JSONB) qui
  # représentent l'entier `floor`. Aucun override par défaut.
  def change do
    alter table(:buildings) do
      add :floor_labels, :map, null: false, default: %{}
    end
  end
end
