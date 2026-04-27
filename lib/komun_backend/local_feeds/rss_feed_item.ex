defmodule KomunBackend.LocalFeeds.RssFeedItem do
  @moduledoc """
  Item RSS extrait par le worker à partir d'un `RssFeed`. La déduplication
  se fait sur `(feed_id, guid)` — le worker fournit un guid de fallback
  basé sur le sha256(url <> title) si le flux ne renseigne pas de guid.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_summary_length 500

  schema "rss_feed_items" do
    field :guid, :string
    field :title, :string
    field :url, :string
    field :summary, :string
    field :image_url, :string
    field :published_at, :utc_datetime

    belongs_to :feed, KomunBackend.LocalFeeds.RssFeed

    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :guid,
      :title,
      :url,
      :summary,
      :image_url,
      :published_at,
      :feed_id
    ])
    |> validate_required([:guid, :title, :url, :feed_id])
    |> validate_length(:guid, max: 512)
    |> validate_length(:title, max: 512)
    |> validate_length(:url, max: 2048)
    |> validate_length(:image_url, max: 2048)
    |> truncate_summary()
    |> unique_constraint([:feed_id, :guid])
    |> foreign_key_constraint(:feed_id)
  end

  defp truncate_summary(changeset) do
    case get_change(changeset, :summary) do
      nil ->
        changeset

      summary when is_binary(summary) ->
        if String.length(summary) > @max_summary_length do
          put_change(changeset, :summary, String.slice(summary, 0, @max_summary_length))
        else
          changeset
        end
    end
  end
end
