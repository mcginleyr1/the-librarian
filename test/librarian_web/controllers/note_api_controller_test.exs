defmodule LibrarianWeb.NoteApiControllerTest do
  use LibrarianWeb.ConnCase, async: true

  import Ecto.Query

  alias Librarian.{Accounts, Repo, Vault}
  alias Librarian.Accounts.User
  alias Librarian.Vault.{Edge, Note}

  defp user! do
    Repo.insert!(%User{email: "api-#{System.unique_integer([:positive])}@example.com"})
  end

  # A fresh token user per test: the auth plug switches the tenant to the
  # token's user, and the test builds its data in that same tenant.
  setup %{conn: conn} do
    user = Accounts.ensure_api_token!(user!())
    Repo.put_user_id(user.id)
    %{conn: put_req_header(conn, "authorization", "Bearer #{user.api_token}"), user: user}
  end

  defp other_users(fun), do: Repo.with_user(user!().id, fun)

  defp note!(attrs, tags \\ []) do
    {:ok, note} = Vault.create_note(Map.merge(%{body: "", clip_mode: "markdown"}, attrs), tags)
    note
  end

  defp touch!(note, updated_at) do
    Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [updated_at: updated_at])
  end

  defp put_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put(path, Jason.encode!(body))
  end

  defp ids(conn), do: conn |> json_response(200) |> Map.fetch!("notes") |> Enum.map(& &1["id"])

  describe "authentication" do
    test "every endpoint requires a bearer token" do
      for conn <- [
            get(build_conn(), ~p"/api/notes"),
            get(build_conn(), ~p"/api/notes/1"),
            put(build_conn(), ~p"/api/notes/external/abc", %{title: "x"})
          ] do
        assert json_response(conn, 401) == %{"error" => "unauthorized"}
      end
    end
  end

  describe "GET /api/notes" do
    test "without q lists the most recently updated notes as summaries", %{conn: conn} do
      {:ok, notebook} = Vault.create_notebook(%{name: "Roam"})
      old = note!(%{title: "Old", notebook_id: notebook.id}, ["elixir"])
      new = note!(%{title: "New"})
      touch!(old, ~U[2030-01-02 00:00:00Z])
      touch!(new, ~U[2030-01-01 00:00:00Z])

      assert %{"notes" => [first, second]} = conn |> get(~p"/api/notes") |> json_response(200)

      assert first == %{
               "id" => old.id,
               "title" => "Old",
               "external_id" => nil,
               "notebook" => %{"id" => notebook.id, "name" => "Roam"},
               "tags" => ["elixir"],
               "clip_mode" => "markdown",
               "source_url" => nil,
               "updated_at" => "2030-01-02T00:00:00Z"
             }

      assert second["id"] == new.id
      assert second["notebook"] == nil
    end

    test "respects limit", %{conn: conn} do
      for i <- 1..3, do: note!(%{title: "Note #{i}"})

      assert conn |> get(~p"/api/notes?limit=2") |> ids() |> length() == 2
    end

    test "with q puts title matches before full-text matches, de-duplicated", %{conn: conn} do
      body_hit = note!(%{title: "Distributed systems", body: "notes on the raft algorithm"})
      title_hit = note!(%{title: "Raft consensus", body: "leader election"})
      _miss = note!(%{title: "Postgres tuning", body: "vacuum"})

      assert conn |> get(~p"/api/notes?q=raft") |> ids() == [title_hit.id, body_hit.id]
    end

    test "never returns another user's notes", %{conn: conn} do
      other_users(fn -> note!(%{title: "Raft secrets", body: "raft"}) end)

      assert conn |> get(~p"/api/notes?q=raft") |> ids() == []
      assert conn |> get(~p"/api/notes") |> ids() == []
    end
  end

  describe "GET /api/notes/:id" do
    test "returns the note with body, format and related notes", %{conn: conn} do
      target = note!(%{title: "Target", body: "x"})
      source = note!(%{title: "Source", body: "see [[Target]]"}, ["roam"])

      note = conn |> get(~p"/api/notes/#{source.id}") |> json_response(200) |> Map.fetch!("note")

      assert %{
               "id" => id,
               "title" => "Source",
               "tags" => ["roam"],
               "body" => "see [[Target]]",
               "body_format" => "markdown",
               "related" => [
                 %{"id" => target_id, "title" => "Target", "kind" => "references"} = rel
               ]
             } = note

      assert id == source.id
      assert target_id == target.id
      assert rel["direction"] == "outgoing"

      incoming = conn |> get(~p"/api/notes/#{target.id}") |> json_response(200)
      assert [%{"direction" => "incoming"}] = incoming["note"]["related"]
    end

    test "clipped notes are html", %{conn: conn} do
      clip = note!(%{title: "Clip", body: "<p>hi</p>", clip_mode: "selection"})

      note = conn |> get(~p"/api/notes/#{clip.id}") |> json_response(200) |> Map.fetch!("note")
      assert note["body_format"] == "html"
    end

    test "404s for another user's note", %{conn: conn} do
      foreign = other_users(fn -> note!(%{title: "Private"}) end)

      assert conn |> get(~p"/api/notes/#{foreign.id}") |> json_response(404) == %{
               "error" => "not_found"
             }
    end

    test "404s for missing and non-integer ids", %{conn: conn} do
      for id <- ["0", "abc", "12abc"] do
        assert json_response(get(conn, ~p"/api/notes/#{id}"), 404) == %{"error" => "not_found"}
      end
    end
  end

  describe "PUT /api/notes/external/:external_id" do
    test "creates a markdown note carrying the external id", %{conn: conn} do
      {:ok, notebook} = Vault.create_notebook(%{name: "Roam"})
      target = note!(%{title: "Target"})

      resp =
        conn
        |> put_json(~p"/api/notes/external/uuid-1", %{
          title: "From Emacs",
          body: "links [[Target]]",
          tags: ["Roam", "roam ", " ", "elixir"],
          notebook_id: to_string(notebook.id),
          source_url: "https://example.com"
        })
        |> json_response(200)

      assert %{"status" => "ok", "id" => id, "created" => true} = resp

      note = Vault.get_note!(id)
      assert note.external_id == "uuid-1"
      assert note.clip_mode == "markdown"
      assert note.notebook_id == notebook.id
      assert note.source_url == "https://example.com"
      assert note.tags |> Enum.map(& &1.name) |> Enum.sort() == ["elixir", "roam"]

      assert [%Edge{target_note_id: target_id}] =
               Repo.all(from e in Edge, where: e.source_note_id == ^id)

      assert target_id == target.id
    end

    test "updates the note already synced under that external id", %{conn: conn} do
      target = note!(%{title: "Target"})

      %{"id" => id} =
        conn
        |> put_json(~p"/api/notes/external/uuid-1", %{title: "v1", body: "x", tags: ["a"]})
        |> json_response(200)

      resp =
        conn
        |> put_json(~p"/api/notes/external/uuid-1", %{title: "v2", body: "now [[Target]]"})
        |> json_response(200)

      assert resp == %{"status" => "ok", "id" => id, "created" => false}

      note = Vault.get_note!(id)
      assert {note.title, note.body} == {"v2", "now [[Target]]"}
      assert Enum.map(note.tags, & &1.name) == ["a"], "omitted tags are left alone"
      assert Repo.get_by!(Edge, source_note_id: id).target_note_id == target.id

      assert conn
             |> put_json(~p"/api/notes/external/uuid-1", %{title: "v3", tags: []})
             |> json_response(200)

      assert Vault.get_note!(id).tags == []
    end

    test "attaches the external id to an unsynced note given by id", %{conn: conn} do
      existing = note!(%{title: "Clip", body: "<p>old</p>", clip_mode: "selection"})

      resp =
        conn
        |> put_json(~p"/api/notes/external/uuid-1", %{id: existing.id, title: "Clip", body: "new"})
        |> json_response(200)

      assert resp == %{"status" => "ok", "id" => existing.id, "created" => false}

      note = Vault.get_note!(existing.id)
      assert {note.external_id, note.clip_mode, note.body} == {"uuid-1", "markdown", "new"}
    end

    test "409s when the id is already synced under another external id", %{conn: conn} do
      %{"id" => id} =
        conn |> put_json(~p"/api/notes/external/uuid-1", %{title: "A"}) |> json_response(200)

      conn = put_json(conn, ~p"/api/notes/external/uuid-2", %{id: id, title: "B"})

      assert json_response(conn, 409) == %{"error" => "external_id_conflict"}
      assert Vault.get_note!(id).title == "A"
    end

    test "404s when the id is unknown or another user's", %{conn: conn} do
      foreign = other_users(fn -> note!(%{title: "Private"}) end)

      for id <- [foreign.id, 0, "abc"] do
        conn = put_json(conn, ~p"/api/notes/external/uuid-1", %{id: id, title: "x"})
        assert json_response(conn, 404) == %{"error" => "not_found"}
      end

      untouched = Repo.with_user(foreign.user_id, fn -> Repo.get!(Note, foreign.id) end)
      assert {untouched.title, untouched.external_id} == {"Private", nil}
    end

    test "another user's identical external id is a different note", %{conn: conn} do
      foreign = other_users(fn -> Vault.sync_note("uuid-1", %{"title" => "Theirs"}) end)
      assert {:ok, %Note{id: foreign_id}, true} = foreign

      resp =
        conn |> put_json(~p"/api/notes/external/uuid-1", %{title: "Mine"}) |> json_response(200)

      assert %{"created" => true, "id" => id} = resp
      assert id != foreign_id
    end

    test "422s without a title", %{conn: conn} do
      conn = put_json(conn, ~p"/api/notes/external/uuid-1", %{body: "x"})

      assert json_response(conn, 422) == %{
               "status" => "error",
               "errors" => %{"title" => ["can't be blank"]}
             }
    end

    test "422s for a notebook the user doesn't own", %{conn: conn} do
      {:ok, foreign} = other_users(fn -> Vault.create_notebook(%{name: "Theirs"}) end)

      conn =
        put_json(conn, ~p"/api/notes/external/uuid-1", %{title: "x", notebook_id: foreign.id})

      assert json_response(conn, 422) == %{
               "status" => "error",
               "errors" => %{"notebook_id" => ["does not exist"]}
             }

      assert Repo.all(Note) == []
    end
  end
end
