defmodule Librarian.Workers.CleanupWorker do
  @moduledoc """
  Garbage-collects the article catalog with
  `Librarian.Reader.delete_stale_read_articles/1` and logs how many were deleted.

  Not in the cron schedule, on purpose. `FeedFetcher` inserts any feed item
  whose guid is not in the database, so an old article that a feed still lists
  comes back as unread on the next poll after this deletes it. Deleting an
  article also cascades to its read states and interactions. Before this is
  scheduled, deleted guids have to be recorded somewhere the fetcher checks.
  """

  use Oban.Worker, queue: :feeds

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    count = Librarian.Reader.delete_stale_read_articles()
    Logger.info("Cleanup: deleted #{count} stale read articles")
    :ok
  end
end
