defmodule KomunBackend.Repo.Migrations.CreateAnnouncements do
  use Ecto.Migration

  def change do
    create table(:announcements, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :title, :string, null: false
      add :body, :text, null: false
      add :category, :string, null: false, default: "info"
      add :is_pinned, :boolean, null: false, default: false
      add :is_published, :boolean, null: false, default: true
      add :publish_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :attachment_urls, {:array, :string}, default: []
      add :read_by_user_ids, {:array, :binary_id}, default: []
      add :building_id, references(:buildings, type: :binary_id, on_delete: :delete_all), null: false
      add :author_id, references(:users, type: :binary_id, on_delete: :nilify_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:announcements, [:building_id])
    create index(:announcements, [:author_id])
    create index(:announcements, [:is_pinned])
    create index(:announcements, [:is_published])
    create index(:announcements, [:inserted_at])
  end
end
