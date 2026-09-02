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
