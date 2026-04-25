defmodule KomunBackendWeb.RssFeedController do
  @moduledoc """
  Endpoints CRUD pour les sources RSS d'une résidence ("Actu locale").

  Lecture (`index`, `items`) : tout membre actif de la résidence.
  Écriture (`create`, `update`, `delete`, `refresh`) : conseil syndical
  (président_cs, membre_cs) + super_admin.

  Les routes sont câblées dans `KomunBackendWeb.Router` via les plugs
  `RequireResidenceMember` et `RequireResidenceAdmin`.
  """
  use KomunBackendWeb, :controller

  alias KomunBackend.LocalFeeds
  alias KomunBackend.LocalFeeds.RssFeed

  # ── Lecture ──────────────────────────────────────────────────────────────

  def index(conn, %{"residence_id" => residence_id}) do
    feeds = LocalFeeds.list_feeds(residence_id)
    json(conn, %{data: Enum.map(feeds, &serialize_feed/1)})
  end

  def items(conn, %{"residence_id" => residence_id} = params) do
    limit =
      params["limit"]
      |> parse_limit(LocalFeeds.default_dashboard_limit())

    items = LocalFeeds.list_recent_items(residence_id, limit: limit)
    json(conn, %{data: Enum.map(items, &serialize_item/1)})
  end

  # ── Écriture ─────────────────────────────────────────────────────────────

  def create(conn, %{"residence_id" => residence_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    attrs =
      params
      |> Map.get("rss_feed", params)
      |> Map.take(["url", "title", "enabled"])
      |> Map.put("residence_id", residence_id)
      |> Map.put("created_by_id", user && user.id)

    case LocalFeeds.create_feed(attrs) do
      {:ok, feed} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_feed(feed)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def update(conn, %{"residence_id" => residence_id, "id" => id} = params) do
    feed = LocalFeeds.get_feed!(id)

    if feed.residence_id != residence_id do
      conn
      |> put_status(:not_found)
      |> json(%{error: "Not found"})
    else
      attrs =
        params
        |> Map.get("rss_feed", params)
        |> Map.take(["url", "title", "enabled"])

      case LocalFeeds.update_feed(feed, attrs) do
        {:ok, updated} ->
          json(conn, %{data: serialize_feed(updated)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    end
  end

  def delete(conn, %{"residence_id" => residence_id, "id" => id}) do
    feed = LocalFeeds.get_feed!(id)

    if feed.residence_id != residence_id do
      conn
      |> put_status(:not_found)
      |> json(%{error: "Not found"})
    else
      {:ok, _} = LocalFeeds.delete_feed(feed)
      send_resp(conn, :no_content, "")
    end
  end

  def refresh(conn, %{"residence_id" => residence_id, "id" => id}) do
    feed = LocalFeeds.get_feed!(id)

    if feed.residence_id != residence_id do
      conn
      |> put_status(:not_found)
      |> json(%{error: "Not found"})
    else
      enqueue_refresh(feed)

      conn
      |> put_status(:accepted)
      |> json(%{data: %{status: "queued", feed_id: feed.id}})
    end
  end

  # ── Sérialisation ─────────────────────────────────────────────────────────

  defp serialize_feed(%RssFeed{} = f) do
    %{
      id: f.id,
      residence_id: f.residence_id,
      url: f.url,
      title: f.title,
      enabled: f.enabled,
      last_fetched_at: f.last_fetched_at,
      last_error: f.last_error,
      consecutive_failures: f.consecutive_failures || 0,
      inserted_at: f.inserted_at,
      updated_at: f.updated_at
    }
  end

  defp serialize_item(item) do
    %{
      id: item.id,
      feed_id: item.feed_id,
      title: item.title,
      url: item.url,
      summary: item.summary,
      image_url: item.image_url,
      published_at: item.published_at,
      inserted_at: item.inserted_at,
      source: item.feed && (item.feed.title || item.feed.url)
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end

  defp parse_limit(nil, default), do: default

  defp parse_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_limit(_, default), do: default

  # Évite un compile-time cycle : on appelle le module Job dynamiquement
  # pour pouvoir le tester à part et le déployer même sans Oban (ex: tests
  # asynchrones unitaires sur le controller, sans mode :inline).
  defp enqueue_refresh(%RssFeed{id: id}) do
    job = KomunBackend.LocalFeeds.Jobs.PollRssFeedJob.new(%{"feed_id" => id})
    Oban.insert(job)
  end
end
