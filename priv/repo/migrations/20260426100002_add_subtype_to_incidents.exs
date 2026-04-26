defmodule KomunBackend.Repo.Migrations.AddSubtypeToIncidents do
  use Ecto.Migration

  # Sous-type explicite de l'incident — permet de cibler les notifications
  # automatiques de voisinage sans dépendre du parsing du titre/description :
  #
  #   - "water_leak" : déclenche NotifyUnitBelowJob (logement en dessous)
  #   - "noise"      : déclenche NotifySameFloorJob (voisins de palier)
  #   - autre / nil  : pas de notification ciblée
  def change do
    alter table(:incidents) do
      add :subtype, :string
    end

    create index(:incidents, [:subtype])
  end
end
