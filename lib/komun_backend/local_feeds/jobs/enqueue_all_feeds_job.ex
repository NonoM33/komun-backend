defmodule KomunBackend.LocalFeeds.Jobs.EnqueueAllFeedsJob do
  @moduledoc """
  Cron worker : enfile un `PollRssFeedJob` pour chaque flux activé.
  La contrainte `unique` du job de poll évite l'empilement si un poll
  précédent est encore en cours pour le même `feed_id`.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias KomunBackend.LocalFeeds
  alias KomunBackend.LocalFeeds.Jobs.PollRssFeedJob

  @impl Oban.Worker
  def perform(_job) do
    LocalFeeds.list_enabled_feeds()
    |> Enum.each(fn feed ->
      %{"feed_id" => feed.id}
      |> PollRssFeedJob.new()
      |> Oban.insert()
    end)

    :ok
  end
end
