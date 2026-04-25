defmodule KomunBackend.Repo.Migrations.CreateRssFeedItems do
  use Ecto.Migration

  def change do
    create table(:rss_feed_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :feed_id,
          references(:rss_feeds, type: :binary_id, on_delete: :delete_all),
          null: false

      add :guid, :string, null: false, size: 512
      add :title, :string, null: false, size: 512
      add :url, :string, null: false, size: 2048
      add :summary, :text
      add :image_url, :string, size: 2048
      add :published_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:rss_feed_items, [:feed_id, :published_at])
    create unique_index(:rss_feed_items, [:feed_id, :guid])
  end
end
