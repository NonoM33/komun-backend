defmodule KomunBackend.Repo.Migrations.CreateRssFeeds do
  use Ecto.Migration

  def change do
    create table(:rss_feeds, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :residence_id,
          references(:residences, type: :binary_id, on_delete: :delete_all),
          null: false

      add :url, :string, null: false, size: 2048
      add :title, :string
      add :enabled, :boolean, null: false, default: true
      add :last_fetched_at, :utc_datetime
      add :last_error, :text
      add :consecutive_failures, :integer, null: false, default: 0

      add :created_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:rss_feeds, [:residence_id])
    create unique_index(:rss_feeds, [:residence_id, :url])
  end
end
