defmodule KomunBackend.LocalFeeds.RssFeed do
  @moduledoc """
  Source RSS configurée par les admins d'une résidence pour alimenter
  le bloc "Actu locale" du dashboard. Les `RssFeedItem` sont peuplés
  par `KomunBackend.LocalFeeds.Jobs.PollRssFeedJob` (Oban).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_url_length 2048

  schema "rss_feeds" do
    field :url, :string
    field :title, :string
    field :enabled, :boolean, default: true
    field :last_fetched_at, :utc_datetime
    field :last_error, :string
    field :consecutive_failures, :integer, default: 0

    belongs_to :residence, KomunBackend.Residences.Residence
    belongs_to :created_by, KomunBackend.Accounts.User
    has_many :items, KomunBackend.LocalFeeds.RssFeedItem, foreign_key: :feed_id

    timestamps(type: :utc_datetime)
  end

  @doc "Create / update changeset (admin-driven)."
  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :url,
      :title,
      :enabled,
      :residence_id,
      :created_by_id
    ])
    |> validate_required([:url, :residence_id])
    |> update_change(:url, &normalize_url/1)
    |> validate_length(:url, max: @max_url_length)
    |> validate_url(:url)
    |> unique_constraint([:residence_id, :url])
    |> foreign_key_constraint(:residence_id)
  end

  @doc """
  Réservé au worker : enregistre l'issue d'un fetch (success/error)
  sans permettre de modifier l'URL ni la résidence.
  """
  def fetch_status_changeset(feed, attrs) do
    feed
    |> cast(attrs, [:enabled, :last_fetched_at, :last_error, :consecutive_failures])
  end

  defp normalize_url(nil), do: nil

  defp normalize_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.replace_trailing("/", "")
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "doit être une URL HTTP(S) valide"}]
      end
    end)
  end
end
