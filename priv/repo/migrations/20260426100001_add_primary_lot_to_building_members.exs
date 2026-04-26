defmodule KomunBackend.Repo.Migrations.AddPrimaryLotToBuildingMembers do
  use Ecto.Migration

  # Lien direct membre → logement principal dans le bâtiment.
  # Permet à Adjacency de retrouver "qui habite tel logement" sans deviner
  # via apartment_number (string libre, source d'erreurs).
  #
  # Nullable parce que tous les rôles ne sont pas liés à un logement
  # spécifique (gardien, prestataire, syndic externe…).
  def change do
    alter table(:building_members) do
      add :primary_lot_id, references(:lots, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:building_members, [:primary_lot_id])
  end
end
