defmodule Librarian.Workers.ScheduleFeedsWorker do
  @moduledoc """
  Cron worker that enqueues a `Librarian.Workers.FetchFeedWorker` job for every
  feed whose fetch interval has elapsed (`Librarian.Reader.list_due_feeds/1`).
  """

  use Oban.Worker, queue: :feeds

  @impl Oban.Worker
  def perform(_job) do
    Librarian.Reader.list_due_feeds()
    |> Enum.each(fn feed ->
      %{feed_id: feed.id}
      |> Librarian.Workers.FetchFeedWorker.new()
      |> Oban.insert()
    end)

    :ok
  end
end
