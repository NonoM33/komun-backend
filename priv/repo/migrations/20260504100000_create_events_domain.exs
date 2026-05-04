defmodule KomunBackend.Repo.Migrations.CreateEventsDomain do
  use Ecto.Migration

  # Migration consolidée pour le domaine `events` (fête des voisins, AG,
  # ateliers, réunions de conseil…). Sept tables livrées en bloc parce
  # qu'elles n'ont aucun usage hors-domaine — découper aurait été du
  # bruit pour la review. Ordre : la table parente d'abord, puis les
  # tables qui la référencent.
  def change do
    # ── Table principale ─────────────────────────────────────────────────
    #
    # Un event vit toujours au niveau de la résidence. Le scope concret
    # (toute la résidence vs. certains bâtiments) est porté par la table
    # `event_building_scopes` : si elle est vide pour un event donné,
    # c'est toute la résidence qui est concernée. Sinon, seuls les
    # bâtiments listés voient l'event — règle stricte « invisible
    # totalement » côté visibility.
    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false
      add :description, :text
      add :cover_image_url, :string

      # festif = fête des voisins / apéro
      # reunion_conseil = réunion CS
      # atelier = jardinage, bricolage…
      # ag = assemblée générale (spécialisations vote/quorum/PV viendront en v2)
      # autre = fallback
      add :kind, :string, null: false, default: "festif"

      add :status, :string, null: false, default: "draft"

      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false

      add :location_label, :string
      add :location_details, :text

      add :max_participants, :integer
      add :requires_registration, :boolean, null: false, default: true
      add :allow_plus_ones, :boolean, null: false, default: true
      add :kid_friendly, :boolean, null: false, default: true

      # Soft-cancel : un event annulé reste visible barré, on garde la
      # raison pour la communiquer aux RSVP.
      add :cancelled_at, :utc_datetime
      add :cancelled_reason, :text

      add :residence_id, references(:residences, type: :binary_id, on_delete: :delete_all),
        null: false

      add :creator_id, references(:users, type: :binary_id, on_delete: :nilify_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:events, [:residence_id])
    create index(:events, [:creator_id])
    create index(:events, [:status])
    create index(:events, [:starts_at])
    create index(:events, [:kind])

    # ── Scope multi-bâtiments ────────────────────────────────────────────
    #
    # Si vide pour un event → toute la résidence. Sinon → uniquement les
    # bâtiments listés. La query côté `Events.list_events_for_building/3`
    # part du building et fait un join pour filtrer.
    create table(:event_building_scopes, primary_key: false) do
      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all),
        null: false, primary_key: true

      add :building_id, references(:buildings, type: :binary_id, on_delete: :delete_all),
        null: false, primary_key: true

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:event_building_scopes, [:building_id])

    # ── Co-organisateurs ─────────────────────────────────────────────────
    #
    # Le créateur est aussi inscrit comme co_organizer pour simplifier le
    # check « peut éditer ». Rôle = creator | co_organizer.
    create table(:event_organizers, primary_key: false) do
      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all),
        null: false, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false, primary_key: true

      add :role, :string, null: false, default: "co_organizer"

      timestamps(type: :utc_datetime)
    end

    create index(:event_organizers, [:user_id])

    # ── RSVP / Participations ────────────────────────────────────────────
    #
    # Une seule ligne par (event, user). plus_ones_count plafonné à 5
    # côté changeset (décision produit : éviter qu'un voisin invite 20
    # externes). dietary_note = champ libre (« végé + allergie arachide »).
    create table(:event_participations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      # going | maybe | declined
      add :status, :string, null: false, default: "going"
      add :plus_ones_count, :integer, null: false, default: 0
      add :dietary_note, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:event_participations, [:event_id, :user_id])
    create index(:event_participations, [:user_id])
    create index(:event_participations, [:status])

    # ── Contributions (potluck) ──────────────────────────────────────────
    #
    # Liste « qui ramène quoi ». L'orga peut pré-remplir un template
    # (entrées/plats/desserts/boissons/matériel), les voisins peuvent
    # claim et aussi AJOUTER leurs propres lignes (« je ramène ma
    # guitare ») — d'où created_by_id, qui peut être l'orga OU un voisin.
    create table(:event_contributions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :string, null: false
      # entree | plat | dessert | boisson | materiel | autre
      add :category, :string, null: false, default: "autre"
      # nil = pas de quantité cible (ex. « ma guitare »)
      add :needed_quantity, :integer

      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:event_contributions, [:event_id])
    create index(:event_contributions, [:category])

    # ── Claims sur contributions ─────────────────────────────────────────
    #
    # Une ligne par (contribution, user). Quantity est l'apport individuel
    # (« je ramène 2 bouteilles »). claimed_quantity affiché dans l'UI =
    # SUM(quantity). Quand on dépasse needed_quantity → l'item bascule
    # en « complet » côté front.
    create table(:event_contribution_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :contribution_id,
          references(:event_contributions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :quantity, :integer, null: false, default: 1
      add :comment, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:event_contribution_claims, [:contribution_id, :user_id])
    create index(:event_contribution_claims, [:user_id])

    # ── Fil de discussion ────────────────────────────────────────────────
    #
    # Commentaires + réactions emoji stockées en jsonb dans la même
    # colonne (forme : %{emoji => %{count, user_ids}}). Pas de table
    # séparée : on évite un N+1 et la maintenance d'une jointure pour
    # une feature qui sert juste à s'envoyer un cœur ou un 🍕.
    create table(:event_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all),
        null: false

      add :author_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :body, :text, null: false
      add :reactions, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:event_comments, [:event_id])
    create index(:event_comments, [:author_id])
  end
end
