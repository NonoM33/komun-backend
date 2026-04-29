defmodule KomunBackend.Repo.Migrations.AddResidenceScopeToCases do
  @moduledoc """
  Permet de rattacher un incident / doléance / diligence soit à un
  bâtiment précis, soit à la résidence entière (auquel cas tous les
  bâtiments de la résidence en héritent dans la liste).

  Pour chaque table :

    * ajoute `residence_id` nullable, FK vers `residences`, `:delete_all`
      sur cascade (cohérent avec `building_id`).
    * passe `building_id` en nullable (était NOT NULL).
    * ajoute un check_constraint XOR : exactement un des deux doit être
      non-null. Ça verrouille l'invariant côté DB pour qu'on ne se
      retrouve pas avec un dossier orphelin (les deux nuls) ni un
      dossier ambigu (les deux remplis) si la validation Ecto rate.
    * ajoute un index sur `residence_id` pour les listes par résidence.

  Réversible.
  """

  use Ecto.Migration

  @tables [:incidents, :doleances, :diligences]

  def up do
    for t <- @tables do
      alter table(t) do
        add :residence_id,
            references(:residences, type: :binary_id, on_delete: :delete_all),
            null: true

        modify :building_id, :binary_id, null: true
      end

      create index(t, [:residence_id])

      create constraint(t, :case_scope_xor,
               check:
                 "(building_id IS NOT NULL AND residence_id IS NULL) OR " <>
                   "(building_id IS NULL AND residence_id IS NOT NULL)"
             )
    end
  end

  def down do
    for t <- @tables do
      drop constraint(t, :case_scope_xor)
      drop index(t, [:residence_id])

      alter table(t) do
        modify :building_id, :binary_id, null: false
        remove :residence_id
      end
    end
  end
end
