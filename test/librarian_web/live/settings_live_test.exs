defmodule LibrarianWeb.SettingsLiveTest do
  use LibrarianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Librarian.Reader

  setup :log_in_owner

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
