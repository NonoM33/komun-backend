defmodule KomunBackend.Repo.Migrations.CreateIncidentComments do
  use Ecto.Migration

  def change do
    create table(:incident_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :body, :text, null: false
      add :photo_urls, {:array, :string}, default: []
      add :is_internal, :boolean, null: false, default: false
      add :incident_id, references(:incidents, type: :binary_id, on_delete: :delete_all), null: false
      add :author_id, references(:users, type: :binary_id, on_delete: :nilify_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:incident_comments, [:incident_id])
    create index(:incident_comments, [:author_id])
  end
end
