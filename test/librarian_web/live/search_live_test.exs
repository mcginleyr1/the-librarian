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

  test "note results link to the note, with tags stripped from the preview", %{conn: conn} do
    {:ok, note} = Vault.create_note(%{title: "Clipped", body: "<p>zebra <b>stripes</b></p>"}, [])

    {:ok, view, _html} = live(conn, ~p"/search?q=zebra")

    assert has_element?(view, ~s(a[href="/vault/note/#{note.id}"]))
    assert render(view) =~ "zebra stripes"
    refute render(view) =~ "&lt;p&gt;"
  end

  test "unknown filters are ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/search")

    render_hook(view, "set_filter", %{"filter" => "nonexistent_atom_xyz"})

    assert has_element?(view, "button.btn-primary", "All")
  end
end
