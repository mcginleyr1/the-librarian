defmodule Librarian.Workers.FeedWorkersTest do
  use Librarian.DataCase, async: true
  use Oban.Testing, repo: Librarian.Repo

  import ExUnit.CaptureLog

  alias Librarian.Reader
  alias Librarian.Reader.Article
  alias Librarian.Workers.{EmbedArticlesWorker, FetchFeedWorker, VetCandidateSourceWorker}

  test "FetchFeedWorker cancels instead of retrying when the feed was deleted" do
    assert {:cancel, :feed_deleted} = perform_job(FetchFeedWorker, %{"feed_id" => -1})
  end

  test "VetCandidateSourceWorker does not queue the same candidate twice" do
    assert {:ok, %Oban.Job{conflict?: false}} =
             Oban.insert(VetCandidateSourceWorker.new(%{id: 7}))

    assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(VetCandidateSourceWorker.new(%{id: 7}))
  end

  test "EmbedArticlesWorker logs and returns the error when embedding fails, leaving rows unembedded" do
    {:ok, feed} = Reader.create_feed(%{title: "F", feed_url: "https://embed.example/feed"})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for i <- 1..3 do
      %Article{}
      |> Article.changeset(%{feed_id: feed.id, guid: "e-#{i}", title: "T#{i}", fetched_at: now})
      |> Repo.insert!()
    end

    log =
      capture_log(fn -> assert {:error, _reason} = perform_job(EmbedArticlesWorker, %{}) end)

    assert length(String.split(log, "EmbedArticlesWorker: batch failed")) == 2
    assert Repo.aggregate(from(a in Article, where: is_nil(a.embedding)), :count) == 3
  end
end
