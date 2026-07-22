defmodule Librarian.Workers.FetchFeedWorker do
  use Oban.Worker,
    queue: :feeds,
    max_attempts: 3,
    unique: [
      keys: [:feed_id],
      states: Oban.Job.states() -- [:completed, :cancelled, :discarded],
      period: :infinity
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"feed_id" => feed_id}}) do
    Librarian.Reader.fetch_feed(feed_id)
  end
end
