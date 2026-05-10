defmodule KomunBackend.Repo.Migrations.CreateCommonResourcesAndBookings do
  use Ecto.Migration

  def change do
    create table(:common_resources, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :description, :text

      # elevator | common_room | parking | bike_room | rooftop | other
      add :kind, :string, null: false, default: "other"

      # Préavis minimum à donner avant la date de début (en heures).
      # 48h par défaut pour l'ascenseur — copropriétaires doivent
      # prévenir le conseil syndical 2 jours avant un déménagement.
      add :advance_notice_hours, :integer, null: false, default: 48

      # Durée maximum d'une réservation (en heures). Ex : 8h pour
      # un déménagement, 4h pour la salle commune.
      add :max_duration_hours, :integer, null: false, default: 8

      # Plage horaire autorisée (heure locale 0..23). On ne réserve pas
      # l'ascenseur à 22h pour ne pas réveiller les voisins.
      add :allowed_hours_start, :integer, null: false, default: 8
      add :allowed_hours_end, :integer, null: false, default: 20

      # Si `true`, une seule réservation à la fois (cas ascenseur). Si
      # `false`, plusieurs réservations peuvent coexister (peu probable
      # en V1 mais ouvre la porte aux locaux à vélos partagés).
      add :exclusive, :boolean, null: false, default: true

      # Désactivable par l'admin sans supprimer la donnée historique
      # (les bookings passés restent visibles).
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:common_resources, [:building_id])
    create index(:common_resources, [:building_id, :active])

    create table(:common_resource_bookings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :common_resource_id,
          references(:common_resources, type: :binary_id, on_delete: :delete_all),
          null: false

      add :requester_id,
          references(:users, type: :binary_id, on_delete: :nilify_all),
          null: false

      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false

      # Motif de la réservation (« Déménagement de M. Untel », « Pot de
      # départ de Mme X »…). Visible côté conseil pour décider, pas une
      # zone PII sensible mais à traiter comme telle quand même.
      add :reason, :text

      # pending | approved | rejected | cancelled
      add :status, :string, null: false, default: "pending"

      # Renseigné par le membre du conseil qui a tranché. Nullable tant
      # que `status == :pending`.
      add :validated_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :validated_at, :utc_datetime
      add :rejection_reason, :text

      timestamps(type: :utc_datetime)
    end

    create index(:common_resource_bookings, [:common_resource_id])
    create index(:common_resource_bookings, [:requester_id])
    create index(:common_resource_bookings, [:status])
    create index(:common_resource_bookings, [:common_resource_id, :status])
  end
end
