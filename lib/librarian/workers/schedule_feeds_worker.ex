defmodule Librarian.Workers.ScheduleFeedsWorker do
  use Oban.Worker, queue: :feeds

  @impl Oban.Worker
  def perform(_job) do
    Librarian.Reader.list_active_feeds()
    |> Enum.each(fn feed ->
      %{feed_id: feed.id}
      |> Librarian.Workers.FetchFeedWorker.new()
      |> Oban.insert()
    end)

    :ok
  end
end
