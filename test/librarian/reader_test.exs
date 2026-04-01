defmodule Librarian.ReaderTest do
  use Librarian.DataCase, async: true

  alias Librarian.Reader
  alias Librarian.Reader.{Feed, Article}

  defp feed_attrs(overrides \\ %{}) do
    Map.merge(
      %{title: "Test Feed", feed_url: "https://example.com/feed.rss", category: "Tech"},
      overrides
    )
  end

  defp article_attrs(feed_id, overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Map.merge(
      %{
        feed_id: feed_id,
        guid: "guid-#{:rand.uniform(999_999)}",
        title: "An Article",
        url: "https://example.com/article",
        summary: "A summary",
        fetched_at: now,
        published_at: now
      },
      overrides
    )
  end

  describe "create_feed/1" do
    test "creates a feed with valid attrs" do
      assert {:ok, %Feed{} = feed} = Reader.create_feed(feed_attrs())
      assert feed.title == "Test Feed"
      assert feed.category == "Tech"
      assert feed.active == true
    end

    test "rejects duplicate feed_url" do
      Reader.create_feed(feed_attrs())
      assert {:error, changeset} = Reader.create_feed(feed_attrs())
      assert %{feed_url: ["has already been taken"]} = errors_on(changeset)
    end

    test "requires feed_url" do
      assert {:error, changeset} = Reader.create_feed(%{title: "No URL"})
      assert %{feed_url: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list_active_feeds/0" do
    test "returns only active feeds" do
      {:ok, active} = Reader.create_feed(feed_attrs(%{feed_url: "https://a.com/feed"}))

      {:ok, _inactive} =
        Reader.create_feed(feed_attrs(%{feed_url: "https://b.com/feed", active: false}))

      feeds = Reader.list_active_feeds()
      ids = Enum.map(feeds, & &1.id)
      assert active.id in ids
      refute Enum.any?(feeds, &(&1.active == false))
    end
  end

  describe "list_feeds_by_category/0" do
    test "groups feeds by category" do
      Reader.create_feed(feed_attrs(%{feed_url: "https://a.com/feed", category: "CS"}))
      Reader.create_feed(feed_attrs(%{feed_url: "https://b.com/feed", category: "CS"}))
      Reader.create_feed(feed_attrs(%{feed_url: "https://c.com/feed", category: "Security"}))

      grouped = Reader.list_feeds_by_category()
      assert length(grouped["CS"]) == 2
      assert length(grouped["Security"]) == 1
    end
  end

  describe "mark_read/1 and unread_count/1" do
    setup do
      {:ok, feed} = Reader.create_feed(feed_attrs())
      {:ok, a1} = Repo.insert(Article.changeset(%Article{}, article_attrs(feed.id)))
      {:ok, a2} = Repo.insert(Article.changeset(%Article{}, article_attrs(feed.id)))
      %{feed: feed, a1: a1, a2: a2}
    end

    test "unread count starts at 2", %{feed: feed} do
      assert Reader.unread_count(feed.id) == 2
    end

    test "mark_read decrements unread count", %{feed: feed, a1: a1} do
      Reader.mark_read(a1.id)
      assert Reader.unread_count(feed.id) == 1
    end

    test "mark_read is idempotent", %{feed: feed, a1: a1} do
      Reader.mark_read(a1.id)
      Reader.mark_read(a1.id)
      assert Reader.unread_count(feed.id) == 1
    end
  end

  describe "mark_all_read/0" do
    setup do
      {:ok, feed} = Reader.create_feed(feed_attrs())
      {:ok, a1} = Repo.insert(Article.changeset(%Article{}, article_attrs(feed.id)))
      {:ok, a2} = Repo.insert(Article.changeset(%Article{}, article_attrs(feed.id)))
      {:ok, a3} = Repo.insert(Article.changeset(%Article{}, article_attrs(feed.id)))
      %{feed: feed, a1: a1, a2: a2, a3: a3}
    end

    test "marks only unread articles", %{feed: feed, a1: a1} do
      Reader.mark_read(a1.id)
      assert Reader.unread_count(feed.id) == 2

      Reader.mark_all_read()
      assert Reader.unread_count(feed.id) == 0
    end

    test "does not touch already-read articles' starred state", %{a1: a1} do
      Reader.mark_starred(a1.id, true)
      Reader.mark_all_read()

      article = Reader.get_article!(a1.id)
      assert article.read_state.starred == true
    end
  end

  describe "mark_all_read_for_feed/1" do
    setup do
      {:ok, f1} = Reader.create_feed(feed_attrs(%{feed_url: "https://a.com/feed"}))
      {:ok, f2} = Reader.create_feed(feed_attrs(%{feed_url: "https://b.com/feed"}))
      {:ok, a1} = Repo.insert(Article.changeset(%Article{}, article_attrs(f1.id)))
      {:ok, a2} = Repo.insert(Article.changeset(%Article{}, article_attrs(f2.id)))
      %{f1: f1, f2: f2, a1: a1, a2: a2}
    end

    test "only marks articles in the given feed", %{f1: f1, f2: f2} do
      Reader.mark_all_read_for_feed(f1.id)
      assert Reader.unread_count(f1.id) == 0
      assert Reader.unread_count(f2.id) == 1
    end
  end

  describe "mark_all_read_for_category/1" do
    setup do
      {:ok, f1} =
        Reader.create_feed(feed_attrs(%{feed_url: "https://a.com/feed", category: "Tech"}))

      {:ok, f2} =
        Reader.create_feed(feed_attrs(%{feed_url: "https://b.com/feed", category: "News"}))

      {:ok, _a1} = Repo.insert(Article.changeset(%Article{}, article_attrs(f1.id)))
      {:ok, _a2} = Repo.insert(Article.changeset(%Article{}, article_attrs(f2.id)))
      %{f1: f1, f2: f2}
    end

    test "only marks articles in the given category", %{f1: f1, f2: f2} do
      Reader.mark_all_read_for_category("Tech")
      assert Reader.unread_count(f1.id) == 0
      assert Reader.unread_count(f2.id) == 1
    end
  end

  describe "delete_stale_read_articles/1" do
    setup do
      {:ok, feed} = Reader.create_feed(feed_attrs())
      old = DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:second)
      recent = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, old_read} =
        Repo.insert(
          Article.changeset(
            %Article{},
            article_attrs(feed.id, %{published_at: old, title: "Old Read"})
          )
        )

      {:ok, old_starred} =
        Repo.insert(
          Article.changeset(
            %Article{},
            article_attrs(feed.id, %{published_at: old, title: "Old Starred"})
          )
        )

      {:ok, old_unread} =
        Repo.insert(
          Article.changeset(
            %Article{},
            article_attrs(feed.id, %{published_at: old, title: "Old Unread"})
          )
        )

      {:ok, recent_read} =
        Repo.insert(
          Article.changeset(
            %Article{},
            article_attrs(feed.id, %{published_at: recent, title: "Recent Read"})
          )
        )

      Reader.mark_read(old_read.id)
      Reader.mark_read(old_starred.id)
      Reader.mark_starred(old_starred.id, true)
      Reader.mark_read(recent_read.id)

      %{
        feed: feed,
        old_read: old_read,
        old_starred: old_starred,
        old_unread: old_unread,
        recent_read: recent_read
      }
    end

    test "deletes only old, read, non-starred articles", ctx do
      count = Reader.delete_stale_read_articles(30)
      assert count == 1

      assert Repo.get(Article, ctx.old_starred.id)
      assert Repo.get(Article, ctx.old_unread.id)
      assert Repo.get(Article, ctx.recent_read.id)
      refute Repo.get(Article, ctx.old_read.id)
    end
  end

  describe "mark_starred/2" do
    setup do
      {:ok, feed} = Reader.create_feed(feed_attrs())
      {:ok, article} = Repo.insert(Article.changeset(%Article{}, article_attrs(feed.id)))
      %{article: article}
    end

    test "stars an article", %{article: article} do
      assert {:ok, state} = Reader.mark_starred(article.id, true)
      assert state.starred == true
    end

    test "unstars an article", %{article: article} do
      Reader.mark_starred(article.id, true)
      assert {:ok, state} = Reader.mark_starred(article.id, false)
      assert state.starred == false
    end
  end
end
