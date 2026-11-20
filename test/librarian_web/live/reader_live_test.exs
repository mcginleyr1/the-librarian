defmodule LibrarianWeb.ReaderLiveTest do
  use LibrarianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Librarian.Reader
  alias Librarian.Reader.Article
  alias Librarian.Repo

  setup :log_in_owner

  defp feed_fixture do
    {:ok, feed} =
      Reader.create_feed(%{
        title: "Test Feed",
        feed_url: "https://example.com/feed.rss",
        category: "Tech"
      })

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

  describe "new-articles pill" do
    test "appears on feed_updated broadcast and clears when clicked", %{conn: conn} do
      feed = feed_fixture()
      unread_articles(feed, 5)

      {:ok, view, _html} = live(conn, "/reader")
      refute has_element?(view, "#new-articles-pill")

      send(view.pid, {:feed_updated, feed.id, 3})
      assert view |> element("#new-articles-pill") |> render() =~ "3 new"

      view |> element("#new-articles-pill") |> render_click()
      refute has_element?(view, "#new-articles-pill")
    end

    test "ignores updates for feeds outside the current scope", %{conn: conn} do
      feed = feed_fixture()
      unread_articles(feed, 2)

      {:ok, other} =
        Reader.create_feed(%{
          title: "Other",
          feed_url: "https://other.com/feed",
          category: "News"
        })

      {:ok, view, _html} = live(conn, "/reader/feed/#{feed.id}")

      send(view.pid, {:feed_updated, other.id, 4})
      refute has_element?(view, "#new-articles-pill")

      send(view.pid, {:feed_updated, feed.id, 2})
      assert has_element?(view, "#new-articles-pill")
    end
  end

  describe "reading and starring" do
    setup %{conn: conn} do
      feed = feed_fixture()
      [a, b | _] = unread_articles(feed, 3)
      {:ok, view, _html} = live(conn, "/reader")
      %{view: view, feed: feed, a: a, b: b}
    end

    defp item(article), do: "#articles-#{article.id}"

    defp feed_count(view, feed),
      do: view |> element("a[href='/reader/feed/#{feed.id}']") |> render()

    test "starring a just-selected unread article updates the reader and the list", %{
      view: view,
      a: a
    } do
      view |> element(item(a)) |> render_click()
      view |> element("button[phx-click='toggle_star']") |> render_click()

      assert view |> element("button[phx-click='toggle_star']") |> render() =~ "Starred"
      assert has_element?(view, "#{item(a)} .hero-star-solid")
    end

    test "selecting moves the highlight and dims the read title in the list", %{
      view: view,
      a: a,
      b: b
    } do
      assert has_element?(view, "#{item(a)} p.font-medium")

      view |> element(item(a)) |> render_click()
      assert has_element?(view, "#{item(a)}.ring-1")
      refute has_element?(view, "#{item(a)} p.font-medium")

      view |> element(item(b)) |> render_click()
      assert has_element?(view, "#{item(b)}.ring-1")
      refute has_element?(view, "#{item(a)}.ring-1")
    end

    test "unread count only drops for articles that were unread", %{view: view, feed: feed, a: a} do
      assert feed_count(view, feed) =~ "3"

      view |> element(item(a)) |> render_click()
      assert feed_count(view, feed) =~ "2"

      view |> element(item(a)) |> render_click()
      assert feed_count(view, feed) =~ "2"
    end

    test "keyboard navigation and starring record the same interactions as clicks", %{
      view: view,
      a: a
    } do
      render_hook(view, "key_nav", %{"key" => "j"})
      assert has_element?(view, "#{item(a)}.ring-1")
      assert Librarian.Stream.signal_summary()["open"] == 1

      render_hook(view, "key_nav", %{"key" => "s"})
      assert has_element?(view, "#{item(a)} .hero-star-solid")
      assert Librarian.Stream.signal_summary()["save"] == 1
    end

    test "a read article that has left the unread list is not put back", %{
      view: view,
      a: a,
      b: b
    } do
      view |> element(item(a)) |> render_click()
      render_hook(view, "show_new_articles", %{})
      refute has_element?(view, item(a))

      view |> element("button[phx-click='toggle_star']") |> render_click()
      refute has_element?(view, item(a))

      view |> element(item(b)) |> render_click()
      refute has_element?(view, item(a))
    end

    test "an unknown filter is ignored", %{view: view} do
      render_hook(view, "set_filter", %{"filter" => "bogus"})
      assert has_element?(view, "#article-list")
    end
  end

  defp stream_item_count(html) do
    ~r/id="articles-\d+"/
    |> Regex.scan(html)
    |> length()
  end
end
