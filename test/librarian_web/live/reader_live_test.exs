defmodule LibrarianWeb.ReaderLiveTest do
  use LibrarianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Librarian.Reader.{Article, Feed}
  alias Librarian.Repo

  defp feed_fixture do
    {:ok, feed} =
      %Feed{}
      |> Feed.changeset(%{
        title: "Test Feed",
        feed_url: "https://example.com/feed.rss",
        category: "Tech"
      })
      |> Repo.insert()

    feed
  end

  defp unread_articles(feed, n) do
    base = DateTime.utc_now() |> DateTime.truncate(:second)

    for i <- 1..n do
      {:ok, article} =
        %Article{}
        |> Article.changeset(%{
          feed_id: feed.id,
          guid: "guid-#{i}",
          title: "Article #{i}",
          url: "https://example.com/article-#{i}",
          summary: "Summary #{i}",
          fetched_at: base,
          published_at: DateTime.add(base, -i, :second)
        })
        |> Repo.insert()

      article
    end
  end

  describe "infinite scroll" do
    test "renders the viewport-bottom load_more trigger when a full page is available", %{
      conn: conn
    } do
      feed = feed_fixture()
      unread_articles(feed, 60)

      {:ok, view, _html} = live(conn, "/reader")

      assert has_element?(view, "#article-list[phx-viewport-bottom='load_more']")
      assert view |> element("#article-list") |> render() |> stream_item_count() == 50
    end

    test "omits the trigger when fewer than a page of articles exist", %{conn: conn} do
      feed = feed_fixture()
      unread_articles(feed, 5)

      {:ok, view, _html} = live(conn, "/reader")

      refute has_element?(view, "#article-list[phx-viewport-bottom]")
      assert view |> element("#article-list") |> render() |> stream_item_count() == 5
    end

    test "load_more appends the next page of articles", %{conn: conn} do
      feed = feed_fixture()
      unread_articles(feed, 60)

      {:ok, view, _html} = live(conn, "/reader")
      assert view |> element("#article-list") |> render() |> stream_item_count() == 50

      render_hook(view, "load_more", %{})

      assert view |> element("#article-list") |> render() |> stream_item_count() == 60
      refute has_element?(view, "#article-list[phx-viewport-bottom]")
    end
  end

  defp stream_item_count(html) do
    ~r/id="articles-\d+"/
    |> Regex.scan(html)
    |> length()
  end
end
