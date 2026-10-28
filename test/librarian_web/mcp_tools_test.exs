defmodule LibrarianWeb.McpToolsTest do
  use LibrarianWeb.ConnCase, async: true

  import Ecto.Query

  alias Librarian.{Accounts, Reader, Repo, Vault}
  alias Librarian.Accounts.User
  alias Librarian.Reader.Article
  alias Librarian.Vault.{Edge, Note}

  defp user!,
    do: Repo.insert!(%User{email: "mcp-#{System.unique_integer([:positive])}@example.com"})

  # A fresh token user per test, whose tenant the test builds its data in.
  setup %{conn: conn} do
    user = Accounts.ensure_api_token!(user!())
    Repo.put_user_id(user.id)
    %{conn: put_req_header(conn, "authorization", "Bearer #{user.api_token}"), user: user}
  end

  defp other_users(fun), do: Repo.with_user(user!().id, fun)

  # tools/call over the 2026-07-28 transport; {:ok, decoded JSON} or {:error, text}.
  defp call(conn, name, arguments \\ %{}) do
    version = "2026-07-28"

    result =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", version)
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", name)
      |> post(
        ~p"/mcp",
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: name,
            arguments: arguments,
            _meta: %{
              "io.modelcontextprotocol/protocolVersion" => version,
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          }
        })
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert %{"resultType" => "complete", "content" => [%{"type" => "text", "text" => text}]} =
             result

    if result["isError"], do: {:error, text}, else: {:ok, Jason.decode!(text)}
  end

  defp note!(attrs, tags \\ []) do
    {:ok, note} = Vault.create_note(Map.merge(%{body: "", clip_mode: "markdown"}, attrs), tags)
    note
  end

  defp article!(attrs) do
    {:ok, feed} =
      Reader.create_feed(%{
        title: "Distributed Weekly",
        feed_url: "https://feeds-#{System.unique_integer([:positive])}.example/rss"
      })

    Repo.insert!(
      struct(
        %Article{
          feed_id: feed.id,
          guid: "g-#{System.unique_integer()}",
          fetched_at: DateTime.utc_now(:second)
        },
        attrs
      )
    )
  end

  defp ids(%{"notes" => notes}), do: Enum.map(notes, & &1["id"])

  describe "search_notes" do
    test "puts title matches before full-text matches", %{conn: conn} do
      body_hit = note!(%{title: "Distributed systems", body: "notes on the raft algorithm"})
      title_hit = note!(%{title: "Raft consensus", body: "leader election"})
      _miss = note!(%{title: "Postgres tuning", body: "vacuum"})

      assert {:ok, result} = call(conn, "search_notes", %{query: "raft"})
      assert ids(result) == [title_hit.id, body_hit.id]
      assert %{"title" => "Raft consensus", "tags" => [], "notebook" => nil} = hd(result["notes"])
    end

    test "filters by notebook and lists recent notes without a query", %{conn: conn} do
      {:ok, notebook} = Vault.create_notebook(%{name: "Papers"})
      filed = note!(%{title: "Raft paper", notebook_id: notebook.id})
      _loose = note!(%{title: "Raft musings"})

      assert {:ok, result} =
               call(conn, "search_notes", %{query: "raft", notebook_id: notebook.id})

      assert ids(result) == [filed.id]

      assert {:ok, result} = call(conn, "search_notes", %{query: "", limit: 1})
      assert length(result["notes"]) == 1
    end

    test "never returns another user's notes", %{conn: conn} do
      other_users(fn -> note!(%{title: "Raft secrets", body: "raft"}) end)

      assert {:ok, %{"notes" => []}} = call(conn, "search_notes", %{query: "raft"})
      assert {:ok, %{"notes" => []}} = call(conn, "search_notes")
    end

    test "rejects arguments of the wrong type", %{conn: conn} do
      assert {:error, "limit must be an integer"} = call(conn, "search_notes", %{limit: "ten"})
    end
  end

  describe "read_note" do
    test "returns a markdown note with its connections", %{conn: conn} do
      target = note!(%{title: "Target", body: "x"})
      source = note!(%{title: "Source", body: "see [[Target]]"}, ["roam"])

      assert {:ok, %{"note" => note}} = call(conn, "read_note", %{id: source.id})

      assert %{
               "title" => "Source",
               "tags" => ["roam"],
               "body" => "see [[Target]]",
               "file" => nil,
               "related" => [%{"id" => target_id, "direction" => "outgoing"}]
             } = note

      assert target_id == target.id
    end

    test "converts clipped HTML to markdown", %{conn: conn} do
      html = """
      <html><head><title>x</title><style>p { color: red }</style></head><body>
      <h2>Leader   election</h2>
      <p>Read <a href="https://raft.github.io">the paper</a> &amp; <strong>vote</strong>.<br>Next line</p>
      <script>alert(1)</script>
      <ul><li>one</li><li>two</li></ul>
      <pre><code>if term &gt; current:
          step_down()</code></pre>
      </body></html>
      """

      clip = note!(%{title: "Clip", body: html, clip_mode: "full_article"})

      assert {:ok, %{"note" => %{"body" => body}}} = call(conn, "read_note", %{id: clip.id})

      assert body == """
             ## Leader election

             Read [the paper](https://raft.github.io) & **vote**.
             Next line

             - one
             - two

             ```
             if term > current:
                 step_down()
             ```\
             """
    end

    test "points at the stored file of a file-backed clip", %{conn: conn} do
      pdf = note!(%{title: "Paper", body: nil, clip_mode: "pdf", storage_key: "clips/1/a.pdf"})

      assert {:ok, %{"note" => note}} = call(conn, "read_note", %{id: pdf.id})
      assert note["body"] == nil

      assert note["file"] == %{
               "url" => "/api/notes/#{pdf.id}/file",
               "content_type" => "application/pdf"
             }
    end

    test "another user's note looks missing", %{conn: conn} do
      foreign = other_users(fn -> note!(%{title: "Private"}) end)

      assert {:error, "Note #{foreign.id} not found"} ==
               call(conn, "read_note", %{id: foreign.id})

      assert {:error, "id is required"} = call(conn, "read_note")
    end
  end

  describe "list_notebooks" do
    test "lists only the user's notebooks", %{conn: conn} do
      {:ok, mine} = Vault.create_notebook(%{name: "Mine"})
      other_users(fn -> Vault.create_notebook(%{name: "Theirs"}) end)

      assert {:ok, %{"notebooks" => [%{"id" => id, "name" => "Mine"}]}} =
               call(conn, "list_notebooks")

      assert id == mine.id
    end
  end

  describe "save_note" do
    test "creates a markdown note with tags, notebook and wiki-link edges", %{conn: conn} do
      {:ok, notebook} = Vault.create_notebook(%{name: "Inbox"})
      target = note!(%{title: "Target"})

      assert {:ok, %{"id" => id, "created" => true, "title" => "Idea"}} =
               call(conn, "save_note", %{
                 title: "Idea",
                 body: "builds on [[Target]]",
                 tags: ["ray"],
                 notebook_id: notebook.id,
                 source_url: "https://example.com"
               })

      note = Vault.get_note!(id)

      assert {note.clip_mode, note.notebook_id, note.external_id} ==
               {"markdown", notebook.id, nil}

      assert note.source_url == "https://example.com"
      assert Enum.map(note.tags, & &1.name) == ["ray"]
      assert Repo.get_by!(Edge, source_note_id: id).target_note_id == target.id
    end

    test "upserts by external_id and rebuilds edges", %{conn: conn} do
      target = note!(%{title: "Target"})

      assert {:ok, %{"id" => id, "created" => true}} =
               call(conn, "save_note", %{
                 title: "v1",
                 body: "x",
                 tags: ["a"],
                 external_id: "ray:1"
               })

      assert {:ok, %{"id" => ^id, "created" => false}} =
               call(conn, "save_note", %{
                 title: "v2",
                 body: "now [[Target]]",
                 external_id: "ray:1"
               })

      note = Vault.get_note!(id)
      assert {note.title, note.body, note.external_id} == {"v2", "now [[Target]]", "ray:1"}
      assert Enum.map(note.tags, & &1.name) == ["a"], "omitted tags are left alone"
      assert Repo.get_by!(Edge, source_note_id: id).target_note_id == target.id
      assert Repo.aggregate(from(n in Note, where: n.external_id == "ray:1"), :count) == 1
    end

    test "won't file into another user's notebook", %{conn: conn} do
      {:ok, foreign} = other_users(fn -> Vault.create_notebook(%{name: "Theirs"}) end)

      assert {:error, "notebook_id does not exist"} =
               call(conn, "save_note", %{title: "x", body: "y", notebook_id: foreign.id})

      assert Repo.all(Note) == []
    end

    test "requires a title and body", %{conn: conn} do
      assert {:error, "title is required"} = call(conn, "save_note", %{title: "", body: "y"})
      assert {:error, "body is required"} = call(conn, "save_note", %{title: "x"})

      assert {:error, "tags must be a list of strings"} =
               call(conn, "save_note", %{title: "x", body: "y", tags: [1]})
    end
  end

  describe "articles" do
    test "search_articles finds the user's feed articles", %{conn: conn} do
      article =
        article!(%{
          title: "Consensus in practice",
          url: "https://example.com/raft",
          summary: "How raft elects leaders"
        })

      _other = article!(%{title: "Gardening", summary: "tomatoes"})

      assert {:ok, %{"articles" => [found]}} = call(conn, "search_articles", %{query: "raft"})

      assert found == %{
               "id" => article.id,
               "title" => "Consensus in practice",
               "feed" => "Distributed Weekly",
               "url" => "https://example.com/raft",
               "author" => nil,
               "published_at" => nil,
               "summary" => "How raft elects leaders"
             }
    end

    test "read_article returns the content as markdown", %{conn: conn} do
      article = article!(%{title: "Raft", content: "<p>Terms <em>never</em> go back.</p>"})

      assert {:ok,
              %{
                "article" => %{
                  "content" => "Terms _never_ go back.",
                  "feed" => "Distributed Weekly"
                }
              }} =
               call(conn, "read_article", %{id: article.id})
    end

    test "another user's private feed articles look missing", %{conn: conn} do
      foreign = other_users(fn -> article!(%{title: "Raft secrets", summary: "raft"}) end)

      assert {:ok, %{"articles" => []}} = call(conn, "search_articles", %{query: "raft"})

      assert {:error, "Article #{foreign.id} not found"} ==
               call(conn, "read_article", %{id: foreign.id})
    end
  end
end
