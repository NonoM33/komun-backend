defmodule KomunBackend.LocalFeeds.Jobs.PollRssFeedJob do
  @moduledoc """
  Worker Oban : récupère un flux RSS/Atom, parse, dédupe et insère ses
  items dans `rss_feed_items`. Un échec non-critique (HTTP 4xx/5xx,
  timeout, body trop gros, parsing impossible) est consigné via
  `LocalFeeds.record_fetch_error/2` et le job termine `:ok` pour ne pas
  alimenter la file de retry Oban (les retries n'aideraient pas si la
  source est cassée — on s'en remet au prochain cron).

  Sécurité réseau :
    - Schemes HTTP/HTTPS seulement (validé deux fois : changeset + ici)
    - 3 redirections max
    - 10 s reçu / 5 s connect
    - 5 MB max sur la réponse
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:args, :worker],
      states: [:available, :scheduled, :executing]
    ]

  require Logger

  alias KomunBackend.LocalFeeds
  alias KomunBackend.LocalFeeds.{Parser, RssFeed}

  @max_response_bytes 5 * 1024 * 1024
  @user_agent "KomunBot/1.0 (+https://komun.app)"

  # Le client HTTP est résolu à l'exécution (pas au compile time) pour
  # permettre aux tests d'injecter un stub via `Application.put_env/3`
  # sans avoir à recompiler le module.
  defp http_client do
    Application.get_env(
      :komun_backend,
      :rss_http_client,
      KomunBackend.LocalFeeds.HttpClient
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"feed_id" => feed_id}}) do
    case LocalFeeds.get_feed(feed_id) do
      nil ->
        # Le flux a pu être supprimé entre l'enqueue et l'exécution.
        :ok

      %RssFeed{} = feed ->
        do_perform(feed)
    end
  end

  defp do_perform(%RssFeed{} = feed) do
    with :ok <- check_url(feed.url),
         {:ok, body} <- fetch_body(feed.url),
         {:ok, items_attrs} <- Parser.parse(body) do
      {ok_count, _errors} = LocalFeeds.insert_items(feed.id, items_attrs)

      LocalFeeds.trim_items(feed.id, LocalFeeds.retention_limit())
      {:ok, _} = LocalFeeds.record_fetch_success(feed)

      Logger.info(
        "[rss] feed #{feed.id} OK — #{ok_count}/#{length(items_attrs)} items inserted"
      )

      :ok
    else
      {:error, reason} ->
        reason_str = format_reason(reason)
        Logger.warning("[rss] feed #{feed.id} ERR — #{reason_str}")
        {:ok, _} = LocalFeeds.record_fetch_error(feed, reason_str)
        :ok
    end
  end

  defp check_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> :ok
      _ -> {:error, :invalid_url_scheme}
    end
  end

  defp fetch_body(url) do
    case http_client().get(url,
           max_redirects: 3,
           receive_timeout: 10_000,
           connect_timeout: 5_000,
           max_response_bytes: @max_response_bytes,
           user_agent: @user_agent
         ) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
