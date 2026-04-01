defmodule Librarian.Workers.CleanupWorker do
  use Oban.Worker, queue: :feeds

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    count = Librarian.Reader.delete_stale_read_articles()
    Logger.info("Cleanup: deleted #{count} stale read articles")
    :ok
  end
end
