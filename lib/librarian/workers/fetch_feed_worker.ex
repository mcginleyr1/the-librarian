defmodule Librarian.Workers.FetchFeedWorker do
  @moduledoc """
  Fetches one feed (`%{"feed_id" => id}`) via `Librarian.Reader.fetch_feed/1`.
  Unique per feed until its job completes, is cancelled or is discarded, so a
  feed is never queued twice.
  """

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

  # Backstop for a stalled server so one feed can't hold a :feeds slot.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)
end
