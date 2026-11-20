defmodule LibrarianWeb.SettingsLiveTest do
  use LibrarianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  use Oban.Testing, repo: Librarian.Repo

  alias Librarian.Reader
  alias Librarian.Workers.{BackupWorker, BuildGraphWorker}

  setup :log_in_owner

  test "an unknown tab falls back to the import tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings?tab=definitely_not_a_tab")

    assert has_element?(view, ".tab-active")
  end

  test "backup button queues a backup for the current user only", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/settings?tab=backup")

    view |> element("#run-backup") |> render_click()

    assert_enqueued(worker: BackupWorker, args: %{user_id: user.id})
    assert [_] = all_enqueued(worker: BackupWorker)
  end

  test "build graph button queues a build for the current user only", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/settings?tab=ai")

    view |> element("#build-graph-now") |> render_click()

    assert_enqueued(worker: BuildGraphWorker, args: %{user_id: user.id})
    assert [_] = all_enqueued(worker: BuildGraphWorker)
  end

  test "category pause deactivates every feed in it; play reactivates", %{conn: conn} do
    {:ok, a} =
      Reader.create_feed(%{title: "A", feed_url: "https://a.example/rss", category: "Insurance"})

    {:ok, b} =
      Reader.create_feed(%{title: "B", feed_url: "https://b.example/rss", category: "Insurance"})

    {:ok, other} =
      Reader.create_feed(%{title: "C", feed_url: "https://c.example/rss", category: "Tech"})

    {:ok, view, _html} = live(conn, "/settings?tab=feeds")

    view |> element("#deactivate-category-Insurance") |> render_click()

    refute Reader.get_feed!(a.id).active
    refute Reader.get_feed!(b.id).active
    assert Reader.get_feed!(other.id).active

    assert has_element?(view, "#activate-category-Insurance")
    view |> element("#activate-category-Insurance") |> render_click()

    assert Reader.get_feed!(a.id).active
    assert Reader.get_feed!(b.id).active
    assert has_element?(view, "#deactivate-category-Insurance")
  end
end
