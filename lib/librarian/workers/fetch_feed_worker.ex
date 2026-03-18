defmodule Librarian.Workers.FetchFeedWorker do
  use Oban.Worker, queue: :feeds, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"feed_id" => feed_id}}) do
    Librarian.Reader.fetch_feed(feed_id)
  end
end
