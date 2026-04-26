defmodule KomunBackend.Repo.Migrations.AddAdjacencyToLots do
  use Ecto.Migration

  # Adjacency between apartment lots — used by Adjacency module to figure out
  # who lives below / above / next to whom for incident notifications
  # (water leak warns the unit below; noise warns same-floor neighbors).
  #
  # Convention par défaut : si `lot.number` matche `^\d+(\d{3})$`, le suffixe
  # 3 chiffres est traité comme la "colonne", et le préfixe comme l'étage.
  # Ex. "2003" → étage 2, colonne 003 → en dessous = "1003".
  #
  # Les colonnes ci-dessous laissent au syndic la possibilité de **forcer**
  # l'adjacence quand la convention casse (immeubles décalés, plans en L,
  # numérotation non standard).
  def change do
    alter table(:lots) do
      add :unit_below_lot_id, references(:lots, type: :binary_id, on_delete: :nilify_all)
      add :unit_above_lot_id, references(:lots, type: :binary_id, on_delete: :nilify_all)
      add :neighbor_lot_ids, {:array, :binary_id}, null: false, default: []
    end

    create index(:lots, [:unit_below_lot_id])
    create index(:lots, [:unit_above_lot_id])
    create index(:lots, [:building_id, :floor])
  end
end
