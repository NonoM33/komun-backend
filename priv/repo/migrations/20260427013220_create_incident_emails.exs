defmodule KomunBackend.Repo.Migrations.CreateIncidentEmails do
  use Ecto.Migration

  def change do
    create table(:incident_emails, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      # Sens et provenance
      add :direction, :string, null: false, default: "inbound"
      add :source, :string, null: false, default: "webhook"

      # Métadonnées email
      add :subject, :string
      add :from_email, :string
      add :from_name, :string
      add :to_email, :string
      add :cc_emails, {:array, :string}, default: []
      add :reply_to, :string
      add :text_body, :text
      add :html_body, :text
      add :raw_text, :text
      add :headers, :map, default: %{}

      # Provider tracking (Resend)
      add :provider, :string, null: false, default: "paste"
      add :provider_message_id, :string
      add :provider_event_id, :string

      # Classification IA
      add :classification, :string
      add :classification_confidence, :float
      add :ai_summary, :text
      add :ai_data, :map, default: %{}
      add :correspondent_kind, :string

      # Statut workflow
      add :status, :string, null: false, default: "received"
      add :error_message, :text

      # Delivery tracking (sortants uniquement)
      add :delivery_status, :string
      add :delivery_events, {:array, :map}, default: []

      # Dates
      add :occurred_at, :utc_datetime
      add :processed_at, :utc_datetime

      # Liens
      add :incident_id,
          references(:incidents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :pasted_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:incident_emails, [:incident_id])
    create index(:incident_emails, [:direction])
    create index(:incident_emails, [:source])
    create index(:incident_emails, [:occurred_at])
    create index(:incident_emails, [:provider_message_id])
    create unique_index(:incident_emails, [:provider, :provider_event_id],
             where: "provider_event_id IS NOT NULL",
             name: :incident_emails_provider_event_unique)
  end
end
