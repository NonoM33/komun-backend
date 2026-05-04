defmodule KomunBackend.Repo.Migrations.CreateEventEmailBlastsAndIndexes do
  use Ecto.Migration

  # Migration ajoute :
  #   - `event_email_blasts` : audit des envois d'email (manuels + auto)
  #     pour rate-limiter côté backend et tracer qui a déclenché quoi.
  #   - colonnes `*_job_id` sur `events` : liens Oban (best-effort) pour
  #     pouvoir annuler les jobs si l'event est cancel/supprimé.
  def change do
    create table(:event_email_blasts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all),
        null: false

      add :triggered_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      # manual_invite | reminder_j1 | gap_j3 | thank_you_j_plus_1
      add :kind, :string, null: false

      add :recipient_count, :integer, null: false, default: 0
      add :subject, :string
      add :body_preview, :text
      add :triggered_ip, :string

      add :sent_at, :utc_datetime, null: false, default: fragment("now()")

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:event_email_blasts, [:event_id])
    create index(:event_email_blasts, [:triggered_by_id])
    create index(:event_email_blasts, [:sent_at])

    # Liens vers les jobs Oban planifiés à la création de l'event.
    # Optionnels : si on n'a pas le bon job_id (ex. event créé en draft
    # avant que les jobs soient programmés), on tolère nil.
    alter table(:events) do
      add :reminder_job_id, :integer
      add :gap_job_id, :integer
      add :thank_you_job_id, :integer
    end
  end
end
