defmodule Librarian.Workers.RebuildInterestWorkerTest do
  use Librarian.DataCase, async: true
  use Oban.Testing, repo: Librarian.Repo

  alias Librarian.Stream
  alias Librarian.Workers.RebuildInterestWorker
  alias Librarian.Reader.Article

  defp article do
    {:ok, feed} =
      Librarian.Reader.create_feed(%{
        title: "F",
        feed_url: "https://x/#{System.unique_integer([:positive])}"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Article{}
    |> Article.changeset(%{
      feed_id: feed.id,
      guid: "g-#{System.unique_integer([:positive])}",
      title: "A",
      fetched_at: now,
      published_at: now
    })
    |> Repo.insert!()
  end

  test "a like enqueues a debounced rebuild" do
    article() |> Map.fetch!(:id) |> Stream.record_interaction(:like)
    assert_enqueued(worker: RebuildInterestWorker)
  end

  test "reading (open) enqueues a rebuild — it is a level-1 positive" do
    article() |> Map.fetch!(:id) |> Stream.record_interaction(:open)
    assert_enqueued(worker: RebuildInterestWorker)
  end

  test "a dislike does not enqueue — the penalty is applied live, not baked in" do
    article() |> Map.fetch!(:id) |> Stream.record_interaction(:dislike)
    refute_enqueued(worker: RebuildInterestWorker)
  end

  test "a burst of signals collapses into a single job" do
    a = article()
    Stream.record_interaction(a.id, :like)
    Stream.record_interaction(a.id, :save)
    Stream.record_interaction(a.id, :open)
    assert length(all_enqueued(worker: RebuildInterestWorker)) == 1
  end

  test "perform runs a rebuild and returns :ok" do
    assert :ok = perform_job(RebuildInterestWorker, %{})
  end
end
