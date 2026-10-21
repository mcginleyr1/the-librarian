defmodule Librarian.Workers.CleanupWorker do
  @moduledoc """
  Garbage-collects the article catalog with
  `Librarian.Reader.delete_stale_read_articles/1` and logs how many were deleted.
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
