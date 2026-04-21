defmodule KomunBackend.Repo.Migrations.AddAiAnswerToIncidents do
  use Ecto.Migration

  def change do
    alter table(:incidents) do
      add :ai_answer, :text
      add :ai_answered_at, :utc_datetime
      add :ai_model, :string
      # Mod workflow: residents can confirm the AI answer solved their issue,
      # or the syndic/conseil can mark it "confirmed" to close quickly.
      add :ai_answer_confirmed_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)
      add :ai_answer_confirmed_at, :utc_datetime
    end
  end
end
