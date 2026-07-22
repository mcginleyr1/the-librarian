defmodule Librarian.Workers.ScheduleFeedsWorkerTest do
  use Librarian.DataCase, async: true
  use Oban.Testing, repo: Librarian.Repo

  alias Librarian.Reader
  alias Librarian.Workers.{FetchFeedWorker, ScheduleFeedsWorker}

  test "enqueues fetches only for due feeds" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, due} = Reader.create_feed(%{title: "Due", feed_url: "https://due.com/feed"})

    {:ok, fresh} =
      Reader.create_feed(%{
        title: "Fresh",
        feed_url: "https://fresh.com/feed",
        last_fetched_at: DateTime.add(now, -5, :minute)
      })

    assert :ok = perform_job(ScheduleFeedsWorker, %{})

    assert_enqueued(worker: FetchFeedWorker, args: %{feed_id: due.id})
    refute_enqueued(worker: FetchFeedWorker, args: %{feed_id: fresh.id})
  end
end
