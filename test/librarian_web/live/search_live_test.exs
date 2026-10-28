defmodule LibrarianWeb.SearchLiveTest do
  use LibrarianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Librarian.{Reader, Repo, Vault}
  alias Librarian.Reader.Article

  setup :log_in_owner

  test "finds feed articles and notes", %{conn: conn} do
    {:ok, feed} =
      Reader.create_feed(%{title: "Distributed Weekly", feed_url: "https://d.example/rss"})

    Repo.insert!(%Article{
      feed_id: feed.id,
      guid: "g1",
      title: "Consensus in practice",
      summary: "How raft elects leaders",
      fetched_at: DateTime.utc_now(:second)
    })

    {:ok, _} = Vault.create_note(%{title: "Raft notes", body: "raft"}, [])

    {:ok, view, _html} = live(conn, ~p"/search?q=raft")

    assert has_element?(view, "a", "Consensus in practice")
    assert has_element?(view, "a", "Distributed Weekly")
    assert has_element?(view, "a", "Raft notes")
  end
end
