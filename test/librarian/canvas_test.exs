defmodule Librarian.CanvasTest do
  use Librarian.DataCase, async: true

  alias Librarian.Accounts.User
  alias Librarian.Canvas
  alias Librarian.Vault
  alias Librarian.Vault.Edge

  defp note!(title, body \\ nil) do
    {:ok, note} = Vault.create_note(%{title: title, body: body || "body of #{title}"})
    note
  end

  defp edges_between(source_id, target_id) do
    Repo.all(
      from e in Edge,
        where: e.source_note_id == ^source_id and e.target_note_id == ^target_id
    )
  end

  # A page holding two note cards joined by one connector.
  defp connected_page!(a, b, edge_attrs \\ %{}) do
    from = Canvas.note_node(a.id, 0, 0)
    to = Canvas.note_node(b.id, 500, 0)
    edge = Map.merge(%{"fromNode" => from["id"], "toNode" => to["id"]}, edge_attrs)

    {:ok, page} =
      Canvas.create_page(%{
        title: "Board",
        doc: %{"nodes" => [from, to], "edges" => [Map.put(edge, "id", "e1")]}
      })

    Canvas.sync_edges()
    page
  end

  describe "create_page/1 and create_page_for_note/1" do
    test "a blank page has an empty document" do
      assert {:ok, page} = Canvas.create_page(%{title: "Scratch"})
      assert page.doc == %{"nodes" => [], "edges" => []}
      assert page.root_note_id == nil
    end

    test "composing from a note seeds the page with that note as its root card" do
      note = note!("Raft consensus")
      assert {:ok, page} = Canvas.create_page_for_note(note)

      assert page.title == "Raft consensus"
      assert page.root_note_id == note.id
      assert [%{"type" => "file", "file" => file, "x" => 0, "y" => 0}] = page.doc["nodes"]
      assert file == "note:#{note.id}"
      assert Canvas.note_ids(page.doc) == [note.id]
    end

    test "requires a title" do
      assert {:error, changeset} = Canvas.create_page(%{title: ""})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "normalize_doc/1" do
    test "keeps only known node types and keys, and truncates coordinates" do
      doc = %{
        "nodes" => [
          %{
            "id" => "t",
            "type" => "text",
            "text" => "hi",
            "x" => 1.9,
            "y" => 2,
            "width" => 100.2,
            "height" => 40,
            "junk" => 1
          },
          %{"id" => "bad", "type" => "video", "x" => 0, "y" => 0, "width" => 1, "height" => 1},
          %{"id" => "nofile", "type" => "file", "x" => 0, "y" => 0, "width" => 1, "height" => 1}
        ],
        "edges" => [
          %{"id" => "e", "fromNode" => "t", "toNode" => "bad"},
          %{"id" => "self", "fromNode" => "t", "toNode" => "t"}
        ]
      }

      assert {:ok, %{"nodes" => [node], "edges" => []}} = Canvas.normalize_doc(doc)

      assert node == %{
               "id" => "t",
               "type" => "text",
               "text" => "hi",
               "x" => 1,
               "y" => 2,
               "width" => 100,
               "height" => 40
             }
    end

    test "drops edge fields with values outside the spec" do
      doc = %{
        "nodes" => [Canvas.text_node(0, 0), Canvas.text_node(10, 10)],
        "edges" => []
      }

      [a, b] = doc["nodes"]

      edge = %{
        "id" => "e",
        "fromNode" => a["id"],
        "toNode" => b["id"],
        "fromSide" => "diagonal",
        "toSide" => "left",
        "toEnd" => "arrow",
        "label" => "extends",
        "extra" => true
      }

      assert {:ok, %{"edges" => [normalized]}} = Canvas.normalize_doc(%{doc | "edges" => [edge]})
      assert normalized == Map.drop(edge, ["fromSide", "extra"])
    end

    test "rejects anything that is not a map" do
      assert :error = Canvas.normalize_doc("nope")
    end
  end

  describe "save_doc/2" do
    test "round-trips a document" do
      {:ok, page} = Canvas.create_page(%{title: "Scratch"})
      node = Canvas.text_node(12, 34, "hello")

      assert {:ok, saved} = Canvas.save_doc(page, Canvas.add_node(page.doc, node))
      assert Canvas.get_page!(saved.id).doc["nodes"] == [node]
    end
  end

  describe "sync_edges/0" do
    test "a connector between two note cards becomes a canvas references edge" do
      a = note!("A")
      b = note!("B")
      connected_page!(a, b)

      assert [edge] = edges_between(a.id, b.id)
      assert edge.kind == "references"
      assert edge.origin == "canvas"
      assert edge.reason == nil
    end

    test "a label naming an edge kind becomes that kind; any other label is kept as the reason" do
      a = note!("A")
      b = note!("B")
      c = note!("C")
      connected_page!(a, b, %{"label" => "Contradicts"})
      connected_page!(a, c, %{"label" => "inspired by"})

      assert [%{kind: "contradicts", reason: nil}] = edges_between(a.id, b.id)
      assert [%{kind: "references", reason: "inspired by"}] = edges_between(a.id, c.id)
    end

    test "connectors touching a text card stay page-local" do
      a = note!("A")
      from = Canvas.note_node(a.id, 0, 0)
      to = Canvas.text_node(400, 0, "scratch")
      edge = %{"id" => "e1", "fromNode" => from["id"], "toNode" => to["id"]}

      {:ok, _page} =
        Canvas.create_page(%{title: "Board", doc: %{"nodes" => [from, to], "edges" => [edge]}})

      Canvas.sync_edges()
      assert Repo.all(from e in Edge, where: e.origin == "canvas") == []
    end

    test "removing the connector or the page removes the mirrored edge" do
      a = note!("A")
      b = note!("B")
      page = connected_page!(a, b)
      assert [_edge] = edges_between(a.id, b.id)

      {:ok, page} = Canvas.save_doc(page, Canvas.remove_edge(page.doc, "e1"))
      assert edges_between(a.id, b.id) == []

      {:ok, page} =
        Canvas.save_doc(
          page,
          Canvas.add_edge(page.doc, %{
            "fromNode" => hd(page.doc["nodes"])["id"],
            "toNode" => List.last(page.doc["nodes"])["id"]
          })
        )

      assert [_edge] = edges_between(a.id, b.id)

      {:ok, _} = Canvas.delete_page(page)
      assert edges_between(a.id, b.id) == []
    end

    test "never steals an edge another origin already owns" do
      b = note!("Target")
      a = note!("Source", "see [[Target]]")
      assert [%{origin: "wikilink"}] = edges_between(a.id, b.id)

      page = connected_page!(a, b)
      assert [%{origin: "wikilink"}] = edges_between(a.id, b.id)

      {:ok, _page} = Canvas.save_doc(page, Canvas.remove_edge(page.doc, "e1"))
      assert [%{origin: "wikilink"}] = edges_between(a.id, b.id)
    end
  end

  describe "promote_text_node/2" do
    test "turns a text card into a vault note and adopts it as the root" do
      text = Canvas.text_node(40, 40, "# Cache invalidation\n\nis hard")

      {:ok, page} =
        Canvas.create_page(%{title: "Scratch", doc: %{"nodes" => [text], "edges" => []}})

      assert {:ok, page} = Canvas.promote_text_node(page, text["id"])

      assert [%{"id" => id, "type" => "file", "file" => "note:" <> note_id}] = page.doc["nodes"]
      assert id == text["id"]
      note = Vault.get_note!(String.to_integer(note_id))
      assert note.title == "Cache invalidation"
      assert note.body == "# Cache invalidation\n\nis hard"
      assert note.clip_mode == "markdown"
      assert page.root_note_id == note.id
    end

    test "keeps an existing root and mirrors connectors once both ends are notes" do
      root = note!("Root")
      root_node = Canvas.note_node(root.id, 0, 0)
      text = Canvas.text_node(500, 0, "a thought")
      edge = %{"id" => "e1", "fromNode" => root_node["id"], "toNode" => text["id"]}

      {:ok, page} =
        Canvas.create_page(%{
          title: "Board",
          root_note_id: root.id,
          doc: %{"nodes" => [root_node, text], "edges" => [edge]}
        })

      assert Vault.related_notes(root.id) == []

      assert {:ok, page} = Canvas.promote_text_node(page, text["id"])
      assert page.root_note_id == root.id

      assert [%{edge: %{origin: "canvas"}, note: %{title: "a thought"}}] =
               Vault.related_notes(root.id)
    end

    test "refuses cards that are not text" do
      note = note!("N")
      {:ok, page} = Canvas.create_page_for_note(note)
      [node] = page.doc["nodes"]

      assert {:error, :not_a_text_node} = Canvas.promote_text_node(page, node["id"])
      assert {:error, :not_a_text_node} = Canvas.promote_text_node(page, "missing")
    end
  end

  describe "document helpers" do
    test "remove_node/2 also drops the node's connectors" do
      a = Canvas.text_node(0, 0, "a")
      b = Canvas.text_node(10, 10, "b")

      doc =
        %{"nodes" => [a, b], "edges" => []}
        |> Canvas.add_edge(%{"fromNode" => a["id"], "toNode" => b["id"]})
        |> Canvas.remove_node(a["id"])

      assert doc == %{"nodes" => [b], "edges" => []}
    end

    test "notes_for/1 loads the notes behind file nodes and ignores unknown ids" do
      note = note!("Known")

      doc = %{
        "nodes" => [Canvas.note_node(note.id, 0, 0), Canvas.note_node(999_999, 0, 0)],
        "edges" => []
      }

      assert Map.keys(Canvas.notes_for(doc)) == [note.id]
    end
  end

  describe "tenancy" do
    test "pages are invisible to other users" do
      {:ok, page} = Canvas.create_page(%{title: "Mine"})

      other =
        Repo.insert!(%User{email: "other-#{System.unique_integer([:positive])}@example.com"})

      Repo.with_user(other.id, fn ->
        assert Canvas.list_pages() == []
        assert_raise Ecto.NoResultsError, fn -> Canvas.get_page!(page.id) end
      end)
    end
  end
end
