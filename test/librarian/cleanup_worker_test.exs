defmodule Librarian.Workers.CleanupWorkerTest do
  use Librarian.DataCase, async: true
  use Oban.Testing, repo: Librarian.Repo

  alias Librarian.Reader
  alias Librarian.Reader.Article

  defp feed_attrs(overrides \\ %{}) do
    Map.merge(
      %{title: "Test Feed", feed_url: "https://example.com/feed-#{:rand.uniform(999_999)}.rss"},
      overrides
    )
  end

  defp article_attrs(feed_id, overrides) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Map.merge(
      %{
        feed_id: feed_id,
        guid: "guid-#{:rand.uniform(999_999)}",
        title: "Article",
        url: "https://example.com/article",
        fetched_at: now,
        published_at: now
      },
      overrides
    )
  end

  test "perform deletes stale read articles" do
    {:ok, feed} = Reader.create_feed(feed_attrs())
    old = DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:second)

    {:ok, old_article} =
      Repo.insert(Article.changeset(%Article{}, article_attrs(feed.id, %{published_at: old})))

    Reader.mark_read(old_article.id)

    assert :ok = perform_job(Librarian.Workers.CleanupWorker, %{})
    refute Repo.get(Article, old_article.id)
  end
end
