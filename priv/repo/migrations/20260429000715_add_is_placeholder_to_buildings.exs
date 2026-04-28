defmodule KomunBackend.Repo.Migrations.AddIsPlaceholderToBuildings do
  use Ecto.Migration

  # Marque les bâtiments "placeholder" : ceux qui ont été auto-créés en
  # même temps qu'une résidence du même nom (cf.
  # `Buildings.create_building/1` → `ensure_residence/1` qui clone le
  # name/address/city du building dans la résidence). Ces bâtiments
  # apparaissent en double dans le dropdown du formulaire d'inscription
  # et dans le switcher de bâtiment, alors que côté UX ils sont juste
  # « la résidence elle-même ».
  #
  # Avant ce flag, le filtrage se faisait par comparaison de strings dans
  # `verify_code` — fragile dès que le nom d'un côté divergeait d'un
  # accent ou d'un espace.
  #
  # Backfill : on flag tout building dont le nom (lowercase + trim +
  # collapse des espaces) matche EXACTEMENT le nom de sa résidence.
  # Volontairement pessimiste : si une résidence a vraiment un seul
  # bâtiment du même nom, l'admin pourra l'unflag depuis l'UI dédiée.
  def change do
    alter table(:buildings) do
      add :is_placeholder, :boolean, null: false, default: false
    end

    flush()

    # Backfill SQL — pas d'Elixir parce qu'on veut zéro dépendance au
    # schema (au cas où il évoluerait). `regexp_replace` collapse les
    # espaces multiples ; `trim` + `lower` font le reste.
    execute(
      """
      UPDATE buildings b
      SET is_placeholder = true
      FROM residences r
      WHERE b.residence_id = r.id
        AND lower(trim(regexp_replace(b.name, '\\s+', ' ', 'g')))
            = lower(trim(regexp_replace(r.name, '\\s+', ' ', 'g')))
      """,
      """
      UPDATE buildings SET is_placeholder = false
      """
    )

    create index(:buildings, [:residence_id, :is_placeholder])
  end
end
