defmodule LibrarianWeb.VaultLiveTest do
  use LibrarianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Librarian.Vault

  setup :log_in_owner

  describe "markdown-first notes" do
    test "a note created in the editor is saved as markdown and rendered", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vault")

      view |> element("button[phx-click='new_note']") |> render_click()

      view
      |> form("#note-form", %{
        "note" => %{"title" => "Markdown note", "body" => "some **bold** text"},
        "tags_input" => ""
      })
      |> render_submit()

      assert [note] = Vault.list_notes()
      assert note.clip_mode == "markdown"
      assert view |> element(".note-body") |> render() =~ "<strong>bold</strong>"
    end

    test "the editor preview tab renders the draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vault")

      view |> element("button[phx-click='new_note']") |> render_click()

      view
      |> form("#note-form", %{"note" => %{"body" => "# Big Heading"}, "tags_input" => ""})
      |> render_change()

      view |> element("#editor-tab-preview") |> render_click()

      assert view |> element("#editor-preview") |> render() =~ "Big Heading</h1>"
    end
  end

  describe "wikilinks" do
    test "resolved [[links]] render as anchors to the target note", %{conn: conn} do
      {:ok, target} = Vault.create_note(%{title: "OTP Supervision", body: "trees"})

      {:ok, note} =
        Vault.create_note(%{
          title: "Source",
          body: "see [[OTP Supervision]] and [[Missing]]",
          clip_mode: "markdown"
        })

      {:ok, view, _html} = live(conn, "/vault/note/#{note.id}")

      assert has_element?(view, ".note-body a[href='/vault/note/#{target.id}']")
      assert view |> element(".note-body") |> render() =~ "[[Missing]]"
    end

    test "the wikilink_suggest hook event replies without crashing the editor", %{conn: conn} do
      {:ok, _target} = Vault.create_note(%{title: "Elixir Metaprogramming", body: "x"})
      {:ok, view, _html} = live(conn, "/vault")

      view |> element("button[phx-click='new_note']") |> render_click()

      # the reply payload isn't exposed by LiveViewTest; the query behind it
      # is covered in Librarian.VaultWikilinksTest — this guards the wiring
      view
      |> element("#note-body-input")
      |> render_hook("wikilink_suggest", %{"q" => "metapro"})

      assert has_element?(view, "#note-form")
    end
  end

  describe "quick switcher" do
    test "⌘K opens, filters, and Enter jumps to the selected note", %{conn: conn} do
      {:ok, target} = Vault.create_note(%{title: "Raft Consensus", body: "x"})
      {:ok, _other} = Vault.create_note(%{title: "Postgres Tuning", body: "y"})

      {:ok, view, _html} = live(conn, "/vault")
      refute has_element?(view, "#quick-switcher")

      view |> element("#vault-root") |> render_hook("open_switcher", %{})
      assert has_element?(view, "#quick-switcher")

      view |> element("#quick-switcher form") |> render_change(%{"q" => "raft"})
      assert has_element?(view, "#switcher-results button", "Raft Consensus")
      refute has_element?(view, "#switcher-results button", "Postgres Tuning")

      view |> element("#quick-switcher form") |> render_submit()
      assert_patch(view, "/vault/note/#{target.id}")
      assert has_element?(view, "h1", "Raft Consensus")
    end

    test "escape closes the switcher", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/vault")

      view |> element("#vault-root") |> render_hook("open_switcher", %{})
      assert has_element?(view, "#quick-switcher")

      view |> element("#switcher-input") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#quick-switcher")
    end

    test "clicking a result navigates to it", %{conn: conn} do
      {:ok, target} = Vault.create_note(%{title: "Clickable Note", body: "x"})
      {:ok, view, _html} = live(conn, "/vault")

      view |> element("#vault-root") |> render_hook("open_switcher", %{})

      view
      |> element("#switcher-results button[phx-value-id='#{target.id}']")
      |> render_click()

      assert_patch(view, "/vault/note/#{target.id}")
    end
  end

  describe "unlinked mentions" do
    test "mentions are listed and one-click linking connects the notes", %{conn: conn} do
      {:ok, note} = Vault.create_note(%{title: "Raft Consensus", body: "the algorithm"})

      {:ok, mentioner} =
        Vault.create_note(%{title: "Reading list", body: "study raft consensus soon"})

      {:ok, view, _html} = live(conn, "/vault/note/#{note.id}")

      assert has_element?(view, "#unlinked-mentions")
      assert has_element?(view, "#link-mention-#{mentioner.id}")

      view |> element("#link-mention-#{mentioner.id}") |> render_click()

      refute has_element?(view, "#unlinked-mentions")
      assert [%{edge: edge}] = Vault.related_notes(note.id)
      assert edge.origin == "user"
      assert edge.kind == "references"
    end
  end
end
