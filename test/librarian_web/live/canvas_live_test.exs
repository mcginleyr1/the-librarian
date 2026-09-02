defmodule LibrarianWeb.CanvasLiveTest do
  use LibrarianWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Librarian.{Canvas, Vault}

  setup :log_in_owner

  defp note!(attrs) do
    {:ok, note} = Vault.create_note(Map.merge(%{title: "Note", body: "body"}, attrs))
    note
  end

  describe "index" do
    test "lists pages and starts a new one", %{conn: conn} do
      {:ok, page} = Canvas.create_page(%{title: "Reading plan"})
      {:ok, view, _html} = live(conn, "/canvas")

      assert has_element?(view, "#page-#{page.id}", "Reading plan")

      view |> element("#new-page") |> render_click()
      assert [new_page] = Enum.reject(Canvas.list_pages(), &(&1.id == page.id))
      assert new_page.title == "Untitled page"
      assert_redirect(view, "/canvas/#{new_page.id}")
    end

    test "deletes a page", %{conn: conn} do
      {:ok, page} = Canvas.create_page(%{title: "Old"})
      {:ok, view, _html} = live(conn, "/canvas")

      view |> element("#page-#{page.id} button[phx-click='delete_page']") |> render_click()

      refute has_element?(view, "#page-#{page.id}")
      assert Canvas.list_pages() == []
    end
  end

  describe "page" do
    test "renders a card per node, with note titles and attachments", %{conn: conn} do
      text_note =
        note!(%{title: "Raft consensus", body: "leader election", clip_mode: "markdown"})

      pdf = note!(%{title: "Paper", clip_mode: "pdf", storage_key: "clips/1.pdf"})
      text = Canvas.text_node(10, 10, "scratch **bold**")

      {:ok, page} =
        Canvas.create_page(%{
          title: "Board",
          doc: %{
            "nodes" => [
              Canvas.note_node(text_note.id, 0, 0),
              Canvas.note_node(pdf.id, 400, 0),
              text
            ],
            "edges" => []
          }
        })

      {:ok, view, _html} = live(conn, "/canvas/#{page.id}")

      assert has_element?(view, "[data-node-id]", "Raft consensus")
      assert has_element?(view, "[data-node-type='file'] .note-body", "leader election")
      assert has_element?(view, "[data-node-id] iframe[src='/vault/files/clips/1.pdf']")

      assert view |> element("#node-#{text["id"]} .note-body") |> render() =~
               "<strong>bold</strong>"
    end

    test "clicking empty space starts a text card in edit mode, and blank cards vanish on blur",
         %{conn: conn} do
      {:ok, page} = Canvas.create_page(%{title: "Board"})
      {:ok, view, _html} = live(conn, "/canvas/#{page.id}")

      view |> element("#canvas-board") |> render_hook("add_text_node", %{"x" => 120, "y" => 80})

      assert [%{"id" => id, "type" => "text", "x" => 120, "y" => 80}] =
               Canvas.get_page!(page.id).doc["nodes"]

      assert has_element?(view, "#text-input-#{id}")

      view
      |> element("#text-form-#{id}")
      |> render_change(%{"node_id" => id, "text" => "first thought"})

      assert [%{"text" => "first thought"}] = Canvas.get_page!(page.id).doc["nodes"]

      view |> element("#text-input-#{id}") |> render_blur(%{"id" => id})
      refute has_element?(view, "#text-input-#{id}")
      assert has_element?(view, "#node-#{id} .note-body", "first thought")

      render_hook(view, "edit_text", %{"id" => id})
      view |> element("#text-form-#{id}") |> render_change(%{"node_id" => id, "text" => "  "})
      view |> element("#text-input-#{id}") |> render_blur(%{"id" => id})

      assert Canvas.get_page!(page.id).doc["nodes"] == []
    end

    test "moving, resizing, and deleting cards persists to the document", %{conn: conn} do
      node = Canvas.text_node(0, 0, "hello")

      {:ok, page} =
        Canvas.create_page(%{title: "Board", doc: %{"nodes" => [node], "edges" => []}})

      {:ok, view, _html} = live(conn, "/canvas/#{page.id}")

      view
      |> element("#canvas-board")
      |> render_hook("move_node", %{"id" => node["id"], "x" => 300, "y" => 150, "height" => 64})

      assert [%{"x" => 300, "y" => 150, "height" => 64}] = Canvas.get_page!(page.id).doc["nodes"]
      assert has_element?(view, "#node-#{node["id"]}[style*='translate(300px,150px)']")

      view
      |> element("#canvas-board")
      |> render_hook("resize_node", %{"id" => node["id"], "width" => 420, "height" => 64})

      assert [%{"width" => 420}] = Canvas.get_page!(page.id).doc["nodes"]

      view |> element("#canvas-board") |> render_hook("delete_node", %{"id" => node["id"]})
      refute has_element?(view, "#node-#{node["id"]}")
      assert Canvas.get_page!(page.id).doc["nodes"] == []
    end

    test "connecting two note cards draws an arrow and mirrors a canvas edge", %{conn: conn} do
      a = note!(%{title: "A"})
      b = note!(%{title: "B"})
      from = Canvas.note_node(a.id, 0, 0)
      to = Canvas.note_node(b.id, 600, 0)

      {:ok, page} =
        Canvas.create_page(%{title: "Board", doc: %{"nodes" => [from, to], "edges" => []}})

      {:ok, view, _html} = live(conn, "/canvas/#{page.id}")

      view
      |> element("#canvas-board")
      |> render_hook("add_edge", %{
        "from" => from["id"],
        "fromSide" => "right",
        "to" => to["id"],
        "toSide" => "left"
      })

      assert [edge] = Canvas.get_page!(page.id).doc["edges"]
      assert %{"fromSide" => "right", "toSide" => "left", "toEnd" => "arrow"} = edge
      assert has_element?(view, "#canvas-edges[data-edges*='#{edge["id"]}']")
      assert [%{edge: %{origin: "canvas", kind: "references"}}] = Vault.related_notes(a.id)

      view
      |> element("#canvas-board")
      |> render_hook("edit_edge", %{"id" => edge["id"], "x" => 300, "y" => 40})

      assert has_element?(view, "#edge-editor")

      view |> element("#edge-editor button", "contradicts") |> render_click()
      refute has_element?(view, "#edge-editor")
      assert [%{"label" => "contradicts"}] = Canvas.get_page!(page.id).doc["edges"]
      assert [%{edge: %{kind: "contradicts"}}] = Vault.related_notes(a.id)

      render_hook(view, "edit_edge", %{"id" => edge["id"], "x" => 300, "y" => 40})

      view
      |> element("#edge-label-form")
      |> render_submit(%{"edge_id" => edge["id"], "label" => "builds on"})

      assert [%{"label" => "builds on"}] = Canvas.get_page!(page.id).doc["edges"]
      assert [%{edge: %{kind: "references", reason: "builds on"}}] = Vault.related_notes(a.id)

      view |> element("#canvas-board") |> render_hook("delete_edge", %{"id" => edge["id"]})
      assert Canvas.get_page!(page.id).doc["edges"] == []
      assert Vault.related_notes(a.id) == []
    end

    test "the drawer finds vault notes and drops them on the page", %{conn: conn} do
      raft = note!(%{title: "Raft consensus"})
      _other = note!(%{title: "Postgres tuning"})
      {:ok, page} = Canvas.create_page(%{title: "Board"})
      {:ok, view, _html} = live(conn, "/canvas/#{page.id}")

      refute has_element?(view, "#vault-drawer")
      view |> element("#drawer-toggle") |> render_click()
      assert has_element?(view, "#vault-drawer [data-drawer-note='#{raft.id}']")

      view |> element("#vault-drawer form") |> render_change(%{"q" => "raft"})
      assert has_element?(view, "#drawer-results button", "Raft consensus")
      refute has_element?(view, "#drawer-results button", "Postgres tuning")

      view
      |> element("#canvas-board")
      |> render_hook("add_note_node", %{"note_id" => raft.id, "x" => 200, "y" => 120})

      assert [%{"type" => "file", "x" => 200, "y" => 120, "height" => 120}] =
               Canvas.get_page!(page.id).doc["nodes"]

      assert has_element?(view, "[data-node-type='file'] h3", "Raft consensus")

      pdf = note!(%{title: "Paper", clip_mode: "pdf", storage_key: "clips/2.pdf"})

      view
      |> element("#canvas-board")
      |> render_hook("add_note_node", %{"note_id" => pdf.id, "x" => 0, "y" => 0})

      assert [_raft, %{"height" => 480}] = Canvas.get_page!(page.id).doc["nodes"]
      assert has_element?(view, "[data-node-id][style*='height:480px'] iframe")
    end

    test "pasted links become link cards and text cards can be saved as notes", %{conn: conn} do
      {:ok, page} = Canvas.create_page(%{title: "Board"})
      {:ok, view, _html} = live(conn, "/canvas/#{page.id}")

      view
      |> element("#canvas-board")
      |> render_hook("add_link_node", %{"url" => "https://example.com/post", "x" => 10, "y" => 10})

      assert has_element?(view, "[data-node-type='link'] a[href='https://example.com/post']")

      view
      |> element("#canvas-board")
      |> render_hook("add_text_node", %{"x" => 400, "y" => 10, "text" => "Fresh idea\n\nDetails"})

      [_link, text] = Canvas.get_page!(page.id).doc["nodes"]
      render_hook(view, "stop_editing", %{"id" => text["id"]})

      view |> element("#node-#{text["id"]} button[phx-click='promote_node']") |> render_click()

      assert [note] = Vault.list_notes()
      assert note.title == "Fresh idea"
      assert has_element?(view, "#node-#{text["id"]}[data-node-type='file'] h3", "Fresh idea")
      assert Canvas.get_page!(page.id).root_note_id == note.id
    end

    test "text cards get [[ suggestions", %{conn: conn} do
      _note = note!(%{title: "OTP Supervision"})
      {:ok, page} = Canvas.create_page(%{title: "Board"})
      {:ok, view, _html} = live(conn, "/canvas/#{page.id}")

      assert render_hook(view, "wikilink_suggest", %{"q" => "otp"})
      assert has_element?(view, "#canvas-board")
    end

    test "deletes the page from its own header", %{conn: conn} do
      {:ok, page} = Canvas.create_page(%{title: "Scratch"})
      {:ok, view, _html} = live(conn, "/canvas/#{page.id}")

      view |> element("#delete-page") |> render_click()

      assert_redirect(view, "/canvas")
      assert Canvas.list_pages() == []
    end

    test "renames the page", %{conn: conn} do
      {:ok, page} = Canvas.create_page(%{title: "Untitled page"})
      {:ok, view, _html} = live(conn, "/canvas/#{page.id}")

      view |> element("#page-title-form") |> render_change(%{"title" => "Q3 reading"})

      assert Canvas.get_page!(page.id).title == "Q3 reading"
      assert page_title(view) =~ "Q3 reading"
    end

    test "another user's page is not found", %{conn: _conn} do
      {:ok, page} = Canvas.create_page(%{title: "Private"})

      other =
        Librarian.Repo.insert!(%Librarian.Accounts.User{
          email: "other-#{System.unique_integer([:positive])}@example.com"
        })

      assert_raise Ecto.NoResultsError, fn ->
        live(log_in_user(build_conn(), other), "/canvas/#{page.id}")
      end
    end
  end
end
