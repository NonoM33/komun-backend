defmodule KomunBackend.LocalFeeds.Jobs.PollRssFeedJobTest do
  @moduledoc """
  Couvre le worker bout-en-bout en stubbant le client HTTP via la
  config `:rss_http_client`. On vérifie : ingestion RSS happy path,
  dédupe, gestion d'erreur HTTP / parse, désactivation après 5 échecs.
  """
  use KomunBackend.DataCase, async: false

  alias KomunBackend.LocalFeeds
  alias KomunBackend.LocalFeeds.{RssFeed, RssFeedItem}
  alias KomunBackend.LocalFeeds.Jobs.PollRssFeedJob

  defmodule StubClient do
    @moduledoc "Stub HTTP basé sur un agent — le test fixe la réponse à servir."

    @behaviour KomunBackend.LocalFeeds.HttpClient.Behaviour

    def start_link(response), do: Agent.start_link(fn -> response end, name: __MODULE__)

    def set(response), do: Agent.update(__MODULE__, fn _ -> response end)

    @impl true
    def get(_url, _opts), do: Agent.get(__MODULE__, & &1)
  end

  defp insert_residence! do
    suffix = System.unique_integer([:positive])

    %KomunBackend.Residences.Residence{}
    |> KomunBackend.Residences.Residence.initial_changeset(%{
      name: "R#{suffix}",
      city: "Wissous",
      postal_code: "91320",
      address: "1 rue X",
      join_code: "T" <> (suffix |> Integer.to_string() |> String.pad_leading(7, "0"))
    })
    |> Repo.insert!()
  end

  defp insert_feed!(residence) do
    %RssFeed{}
    |> RssFeed.changeset(%{
      url: "https://wissous.fr/rss-#{System.unique_integer([:positive])}",
      residence_id: residence.id,
      enabled: true
    })
    |> Repo.insert!()
  end

  setup do
    # L'Agent est nommé : on évite un :already_started entre tests en
    # tolérant ce cas et en forçant la valeur initiale à chaque setup.
    case StubClient.start_link({:error, :not_set}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> StubClient.set({:error, :not_set})
    end

    Application.put_env(:komun_backend, :rss_http_client, StubClient)
    on_exit(fn -> Application.delete_env(:komun_backend, :rss_http_client) end)

    :ok
  end

  test "ingests RSS items and records fetch success" do
    residence = insert_residence!()
    feed = insert_feed!(residence)

    StubClient.set(
      {:ok,
       """
       <rss version="2.0"><channel>
         <item>
           <title>Travaux mairie</title>
           <link>https://wissous.fr/news/1</link>
           <guid>g-1</guid>
           <pubDate>Tue, 21 Apr 2026 10:00:00 GMT</pubDate>
         </item>
       </channel></rss>
       """}
    )

    assert :ok = perform_job(PollRssFeedJob, %{"feed_id" => feed.id})

    assert [item] = Repo.all(RssFeedItem)
    assert item.title == "Travaux mairie"

    reloaded = Repo.get!(RssFeed, feed.id)
    assert reloaded.consecutive_failures == 0
    refute is_nil(reloaded.last_fetched_at)
    assert is_nil(reloaded.last_error)
  end

  test "deduplicates items across runs by (feed_id, guid)" do
    residence = insert_residence!()
    feed = insert_feed!(residence)

    StubClient.set(
      {:ok,
       """
       <rss version="2.0"><channel>
         <item><title>Same</title><link>https://w/x</link><guid>g-1</guid></item>
       </channel></rss>
       """}
    )

    assert :ok = perform_job(PollRssFeedJob, %{"feed_id" => feed.id})
    assert :ok = perform_job(PollRssFeedJob, %{"feed_id" => feed.id})

    assert Repo.aggregate(RssFeedItem, :count) == 1
  end

  test "records last_error on HTTP failure without raising" do
    residence = insert_residence!()
    feed = insert_feed!(residence)

    StubClient.set({:error, "http_status_500"})

    assert :ok = perform_job(PollRssFeedJob, %{"feed_id" => feed.id})

    reloaded = Repo.get!(RssFeed, feed.id)
    assert reloaded.consecutive_failures == 1
    assert reloaded.last_error == "http_status_500"
    assert reloaded.enabled == true
    assert Repo.aggregate(RssFeedItem, :count) == 0
  end

  test "auto-disables the feed after 5 consecutive failures" do
    residence = insert_residence!()
    feed = insert_feed!(residence)

    StubClient.set({:error, "boom"})

    for _ <- 1..5 do
      assert :ok = perform_job(PollRssFeedJob, %{"feed_id" => feed.id})
    end

    reloaded = Repo.get!(RssFeed, feed.id)
    assert reloaded.consecutive_failures == 5
    assert reloaded.enabled == false
  end

  test "no-op when the feed has been deleted between enqueue and exec" do
    assert :ok = perform_job(PollRssFeedJob, %{"feed_id" => Ecto.UUID.generate()})
  end

  defp perform_job(worker, args) do
    job = %Oban.Job{args: args}
    worker.perform(job)
  end
end
