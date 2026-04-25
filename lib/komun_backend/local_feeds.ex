defmodule KomunBackend.LocalFeeds do
  @moduledoc """
  Contexte "Actu locale" : sources RSS configurées par résidence et
  items récupérés en arrière-plan par `LocalFeeds.Jobs.PollRssFeedJob`.

  Conçu pour alimenter le bloc "Actu locale" du dashboard (la mairie,
  la presse locale, etc.). La config est par résidence — chaque CS /
  syndic ajoute les flux pertinents pour sa ville.
  """

  import Ecto.Query

  alias KomunBackend.Repo
  alias KomunBackend.LocalFeeds.{RssFeed, RssFeedItem}

  @max_consecutive_failures 5

  # ── Feeds (CRUD) ─────────────────────────────────────────────────────────

  @doc "Liste les flux configurés pour une résidence (admin + lecture)."
  def list_feeds(residence_id) do
    from(f in RssFeed,
      where: f.residence_id == ^residence_id,
      order_by: [desc: f.enabled, asc: f.inserted_at]
    )
    |> Repo.all()
  end

  def get_feed!(id), do: Repo.get!(RssFeed, id)

  def get_feed(id), do: Repo.get(RssFeed, id)

  def create_feed(attrs) do
    %RssFeed{}
    |> RssFeed.changeset(attrs)
    |> Repo.insert()
  end

  def update_feed(%RssFeed{} = feed, attrs) do
    feed
    |> RssFeed.changeset(attrs)
    |> Repo.update()
  end

  def delete_feed(%RssFeed{} = feed), do: Repo.delete(feed)

  @doc "Liste les flux activés à puller (utilisé par le scheduler)."
  def list_enabled_feeds do
    from(f in RssFeed, where: f.enabled == true)
    |> Repo.all()
  end

  # ── Items (lecture) ──────────────────────────────────────────────────────

  @doc """
  Items récents agrégés sur tous les flux activés d'une résidence,
  triés par `published_at DESC NULLS LAST, inserted_at DESC`.
  """
  def list_recent_items(residence_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10) |> min(50) |> max(1)

    from(item in RssFeedItem,
      join: feed in assoc(item, :feed),
      where: feed.residence_id == ^residence_id and feed.enabled == true,
      order_by: [
        desc_nulls_last: item.published_at,
        desc: item.inserted_at
      ],
      limit: ^limit,
      preload: [:feed]
    )
    |> Repo.all()
  end

  # ── Worker hooks ─────────────────────────────────────────────────────────

  @doc "Compte d'items pour un feed (utilisé par le worker pour la rétention)."
  def count_items(feed_id) do
    Repo.one!(from i in RssFeedItem, where: i.feed_id == ^feed_id, select: count())
  end

  @doc """
  Insère un batch d'attrs d'items en mode upsert (`on_conflict: :nothing`
  sur la contrainte `(feed_id, guid)`). Retourne `{ok_count, errors}`.
  """
  def insert_items(feed_id, items_attrs) when is_list(items_attrs) do
    items_attrs
    |> Enum.reduce({0, []}, fn attrs, {ok, errs} ->
      attrs = Map.put(attrs, :feed_id, feed_id)

      case %RssFeedItem{}
           |> RssFeedItem.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing, conflict_target: [:feed_id, :guid]) do
        {:ok, _item} -> {ok + 1, errs}
        {:error, cs} -> {ok, [{attrs, cs} | errs]}
      end
    end)
  end

  @doc """
  Marque un fetch réussi : remet `consecutive_failures` à 0,
  rafraîchit `last_fetched_at`, efface `last_error`.
  """
  def record_fetch_success(%RssFeed{} = feed, fetched_at \\ DateTime.utc_now()) do
    feed
    |> RssFeed.fetch_status_changeset(%{
      last_fetched_at: DateTime.truncate(fetched_at, :second),
      last_error: nil,
      consecutive_failures: 0
    })
    |> Repo.update()
  end

  @doc """
  Marque un fetch en erreur : incrémente `consecutive_failures`, stocke
  le message, et désactive le flux après `@max_consecutive_failures`
  échecs successifs (le CS / syndic peut le réactiver depuis l'admin).
  """
  def record_fetch_error(%RssFeed{} = feed, reason) when is_binary(reason) do
    new_count = (feed.consecutive_failures || 0) + 1
    auto_disable? = new_count >= @max_consecutive_failures

    feed
    |> RssFeed.fetch_status_changeset(%{
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_error: String.slice(reason, 0, 500),
      consecutive_failures: new_count,
      enabled: if(auto_disable?, do: false, else: feed.enabled)
    })
    |> Repo.update()
  end

  @doc """
  Conserve uniquement les `keep` items les plus récents pour un feed.
  Idempotent ; appelé après chaque insert pour éviter une croissance
  illimitée.
  """
  def trim_items(feed_id, keep) when is_integer(keep) and keep > 0 do
    sub =
      from item in RssFeedItem,
        where: item.feed_id == ^feed_id,
        select: item.id,
        order_by: [
          desc_nulls_last: item.published_at,
          desc: item.inserted_at
        ],
        limit: ^keep

    keep_ids = Repo.all(sub)

    if keep_ids == [] do
      {0, nil}
    else
      from(i in RssFeedItem,
        where: i.feed_id == ^feed_id and i.id not in ^keep_ids
      )
      |> Repo.delete_all()
    end
  end

  @doc "Limit utilisée par défaut côté UI / dashboard."
  def default_dashboard_limit, do: 5

  @doc "Nombre maximum d'items conservés par flux."
  def retention_limit, do: 50
end
