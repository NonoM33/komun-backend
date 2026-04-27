defmodule KomunBackend.LocalFeedsTest do
  use KomunBackend.DataCase, async: true

  alias KomunBackend.LocalFeeds
  alias KomunBackend.LocalFeeds.{RssFeed, RssFeedItem}
  alias KomunBackend.Residences.Residence

  defp insert_residence!(attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      name: "Résidence #{suffix}",
      address: "1 rue des Lilas",
      city: "Wissous",
      postal_code: "91320",
      # `initial_changeset/2` exige `join_code` ; généré localement pour
      # rester unique d'un test à l'autre.
      join_code: "TST" <> Integer.to_string(suffix) |> String.pad_trailing(8, "X")
    }

    %Residence{}
    |> Residence.initial_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_feed!(attrs) do
    %RssFeed{}
    |> RssFeed.changeset(attrs)
    |> Repo.insert!()
  end

  describe "create_feed/1" do
    test "rejects URLs that are not HTTP(S)" do
      r = insert_residence!()

      assert {:error, changeset} =
               LocalFeeds.create_feed(%{url: "ftp://wissous.fr/feed.xml", residence_id: r.id})

      assert %{url: ["doit être une URL HTTP(S) valide"]} = errors_on(changeset)
    end

    test "rejects duplicate URL within the same residence" do
      r = insert_residence!()
      _ = insert_feed!(%{url: "https://wissous.fr/rss", residence_id: r.id})

      assert {:error, changeset} =
               LocalFeeds.create_feed(%{url: "https://wissous.fr/rss", residence_id: r.id})

      # `unique_constraint` rapporte sur le premier champ de l'index
      # composé `(residence_id, url)`. On vérifie le message porté.
      errors = errors_on(changeset)
      assert errors[:residence_id] == ["has already been taken"]
    end

    test "normalises trailing slash to dedupe variants" do
      r = insert_residence!()
      {:ok, _} = LocalFeeds.create_feed(%{url: "https://wissous.fr/rss/", residence_id: r.id})

      assert {:error, _} =
               LocalFeeds.create_feed(%{url: "https://wissous.fr/rss", residence_id: r.id})
    end

    test "accepts the same URL on two different residences" do
      r1 = insert_residence!()
      r2 = insert_residence!()
      url = "https://wissous.fr/rss"

      assert {:ok, _} = LocalFeeds.create_feed(%{url: url, residence_id: r1.id})
      assert {:ok, _} = LocalFeeds.create_feed(%{url: url, residence_id: r2.id})
    end
  end

  describe "list_feeds/1" do
    test "returns feeds for the residence, enabled first" do
      r = insert_residence!()
      _disabled = insert_feed!(%{url: "https://a.fr/rss", residence_id: r.id, enabled: false})
      _enabled = insert_feed!(%{url: "https://b.fr/rss", residence_id: r.id, enabled: true})

      feeds = LocalFeeds.list_feeds(r.id)
      assert length(feeds) == 2
      assert hd(feeds).enabled == true
    end
  end

  describe "list_recent_items/2" do
    test "orders by published_at DESC then inserted_at DESC across enabled feeds only" do
      r = insert_residence!()
      enabled = insert_feed!(%{url: "https://a.fr/rss", residence_id: r.id, enabled: true})
      disabled = insert_feed!(%{url: "https://b.fr/rss", residence_id: r.id, enabled: false})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%RssFeedItem{
        feed_id: enabled.id,
        guid: "old",
        title: "Old",
        url: "https://a.fr/old",
        published_at: DateTime.add(now, -3600, :second)
      })

      Repo.insert!(%RssFeedItem{
        feed_id: enabled.id,
        guid: "new",
        title: "New",
        url: "https://a.fr/new",
        published_at: now
      })

      Repo.insert!(%RssFeedItem{
        feed_id: disabled.id,
        guid: "hidden",
        title: "Hidden",
        url: "https://b.fr/x"
      })

      titles = LocalFeeds.list_recent_items(r.id) |> Enum.map(& &1.title)
      assert titles == ["New", "Old"]
    end

    test "respects the limit option (capped at 50)" do
      r = insert_residence!()
      feed = insert_feed!(%{url: "https://a.fr/rss", residence_id: r.id, enabled: true})

      for i <- 1..3 do
        Repo.insert!(%RssFeedItem{
          feed_id: feed.id,
          guid: "g#{i}",
          title: "T#{i}",
          url: "https://a.fr/#{i}"
        })
      end

      assert length(LocalFeeds.list_recent_items(r.id, limit: 2)) == 2
    end
  end

  describe "record_fetch_error/2" do
    test "increments consecutive_failures and disables after 5 failures" do
      r = insert_residence!()
      feed = insert_feed!(%{url: "https://a.fr/rss", residence_id: r.id, enabled: true})

      Enum.reduce(1..5, feed, fn _, acc ->
        {:ok, updated} = LocalFeeds.record_fetch_error(acc, "boom")
        updated
      end)

      reloaded = Repo.get!(RssFeed, feed.id)
      assert reloaded.consecutive_failures == 5
      assert reloaded.enabled == false
      assert reloaded.last_error == "boom"
    end

    test "record_fetch_success resets the counter" do
      r = insert_residence!()
      feed = insert_feed!(%{url: "https://a.fr/rss", residence_id: r.id, enabled: true})
      {:ok, after_err} = LocalFeeds.record_fetch_error(feed, "boom")
      assert after_err.consecutive_failures == 1

      {:ok, after_ok} = LocalFeeds.record_fetch_success(after_err)
      assert after_ok.consecutive_failures == 0
      assert after_ok.last_error == nil
      assert not is_nil(after_ok.last_fetched_at)
    end
  end

  describe "trim_items/2" do
    test "keeps only the N most recent items per feed" do
      r = insert_residence!()
      feed = insert_feed!(%{url: "https://a.fr/rss", residence_id: r.id, enabled: true})
      base = DateTime.utc_now() |> DateTime.truncate(:second)

      for i <- 1..5 do
        Repo.insert!(%RssFeedItem{
          feed_id: feed.id,
          guid: "g#{i}",
          title: "T#{i}",
          url: "https://a.fr/#{i}",
          published_at: DateTime.add(base, -i * 60, :second)
        })
      end

      LocalFeeds.trim_items(feed.id, 2)
      assert LocalFeeds.count_items(feed.id) == 2

      remaining = LocalFeeds.list_recent_items(r.id, limit: 10) |> Enum.map(& &1.title)
      assert remaining == ["T1", "T2"]
    end
  end
end
