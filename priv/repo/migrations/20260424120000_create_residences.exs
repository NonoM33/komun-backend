defmodule KomunBackend.Repo.Migrations.CreateResidences do
  use Ecto.Migration

  @moduledoc """
  Introduit la hiérarchie **Résidence → Bâtiments**.

  Avant cette migration, un "Building" portait à la fois la notion d'immeuble
  physique ET la notion de copropriété (c'est lui qui détenait le join_code
  partagé aux voisins). Une copropriété multi-bâtiments devait être saisie
  comme N "buildings" sans lien entre eux, ce qui affichait une liste plate
  incohérente côté admin.

  On introduit `residences` comme parent :
  - chaque résidence a son propre join_code (code "générique" de la copro)
  - chaque building peut aussi garder un join_code (code direct bâtiment)
  - `verify_code/1` teste les deux : code résidence → l'user choisit son
    bâtiment ; code bâtiment → join direct.

  Rétrocompatibilité : on promeut automatiquement chaque building existant
  en résidence mono-bâtiment (même name/address/code). Aucune perte de
  données, l'admin pourra ensuite fusionner plusieurs bâtiments sous une
  même résidence via l'UI.
  """

  def up do
    create table(:residences, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string
      add :address, :string
      add :city, :string
      add :postal_code, :string
      add :country, :string, default: "FR"
      add :cover_url, :string
      add :join_code, :string, null: false
      add :settings, :map, default: %{}
      add :is_active, :boolean, default: true, null: false

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:residences, [:join_code])
    create index(:residences, [:organization_id])

    alter table(:buildings) do
      add :residence_id,
          references(:residences, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:buildings, [:residence_id])

    flush()

    # ── Data migration : 1 résidence par building existant ───────────────────
    #
    # On garde le code exact du bâtiment comme code résidence pour éviter que
    # les affiches déjà imprimées dans les halls deviennent invalides. Le code
    # bâtiment, lui, est régénéré après coup (code distinct = join direct).
    execute(fn ->
      repo().query!(
        """
        INSERT INTO residences (
          id, name, slug, address, city, postal_code, country,
          cover_url, join_code, settings, is_active, organization_id,
          inserted_at, updated_at
        )
        SELECT
          gen_random_uuid(),
          b.name,
          lower(regexp_replace(b.name, '[^a-zA-Z0-9]+', '-', 'g')),
          b.address,
          b.city,
          b.postal_code,
          b.country,
          b.cover_url,
          b.join_code,
          b.settings,
          b.is_active,
          b.organization_id,
          NOW(),
          NOW()
        FROM buildings b
        WHERE b.residence_id IS NULL
        """,
        []
      )

      repo().query!(
        """
        UPDATE buildings b
        SET residence_id = r.id
        FROM residences r
        WHERE b.residence_id IS NULL
          AND r.join_code = b.join_code
        """,
        []
      )

      # Génère un code bâtiment distinct du code résidence pour préserver les
      # deux types d'invitation. On utilise un md5 différent pour éviter la
      # collision avec l'existant (contraint par unique_index).
      repo().query!(
        """
        UPDATE buildings
        SET join_code = upper(substr(md5(gen_random_uuid()::text || id::text), 1, 8))
        """,
        []
      )
    end)

    # À ce stade, tous les buildings ont une residence_id. On peut rendre la
    # colonne obligatoire.
    alter table(:buildings) do
      modify :residence_id, :binary_id, null: false
    end
  end

  def down do
    alter table(:buildings) do
      modify :residence_id, :binary_id, null: true
    end

    # Avant de drop la table, on recolle le code résidence sur chaque building
    # pour qu'un rollback n'invalide pas les affiches du hall.
    execute(fn ->
      repo().query!(
        """
        UPDATE buildings b
        SET join_code = r.join_code
        FROM residences r
        WHERE b.residence_id = r.id
        """,
        []
      )
    end)

    drop index(:buildings, [:residence_id])

    alter table(:buildings) do
      remove :residence_id
    end

    drop index(:residences, [:organization_id])
    drop unique_index(:residences, [:join_code])
    drop table(:residences)
  end
end
