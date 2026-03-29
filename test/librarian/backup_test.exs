defmodule Librarian.BackupTest do
  use Librarian.DataCase, async: true

  alias Librarian.Backup
  alias Librarian.Vault.{Note, Notebook, Tag}

  describe "slugify/1" do
    test "lowercases and hyphenates" do
      assert Backup.slugify("Hello World") == "hello-world"
    end

    test "strips non-alphanumeric characters" do
      assert Backup.slugify("My Note! (2026)") == "my-note-2026"
    end

    test "collapses multiple hyphens" do
      assert Backup.slugify("foo  --  bar") == "foo-bar"
    end

    test "handles nil" do
      assert Backup.slugify(nil) == "untitled"
    end

    test "handles empty string" do
      assert Backup.slugify("") == ""
    end
  end

  describe "note_key/2" do
    test "returns correct B2 key path" do
      note = %Note{id: 42, title: "My Note"}
      assert Backup.note_key(note, "Research") == "vault/research/42-my-note/index.md"
    end

    test "handles nil title" do
      note = %Note{id: 7, title: nil}
      assert Backup.note_key(note, "Inbox") == "vault/inbox/7-untitled/index.md"
    end
  end

  describe "attachment_key/2" do
    test "returns correct B2 key with extension from storage_key" do
      note = %Note{id: 5, title: "A Note", storage_key: "clips/abc123.pdf"}
      assert Backup.attachment_key(note, "Work") == "vault/work/5-a-note/attachment.pdf"
    end

    test "handles storage_key with nested path" do
      note = %Note{id: 3, title: "Screenshot", storage_key: "screenshots/2026/img.png"}
      assert Backup.attachment_key(note, "Inbox") == "vault/inbox/3-screenshot/attachment.png"
    end
  end

  describe "render_markdown/2" do
    test "renders note with all fields" do
      note = %Note{
        id: 1,
        title: "Test Note",
        body: "Hello world",
        source_url: "https://example.com",
        clip_mode: "full_article",
        inserted_at: ~U[2026-01-15 10:30:00Z],
        original_created_at: ~U[2026-01-14 08:00:00Z],
        notebook: %Notebook{name: "Research"},
        tags: [%Tag{name: "elixir"}, %Tag{name: "phoenix"}]
      }

      result = Backup.render_markdown(note, "Research")

      assert result =~ ~s(title: "Test Note")
      assert result =~ ~s(notebook: "Research")
      assert result =~ ~s(tags: ["elixir", "phoenix"])
      assert result =~ ~s(source_url: "https://example.com")
      assert result =~ "clip_mode: full_article"
      assert result =~ "created_at: 2026-01-14"
      assert result =~ "Hello world"
    end

    test "omits nil fields from frontmatter" do
      note = %Note{
        id: 2,
        title: "Simple",
        body: "Content",
        source_url: nil,
        clip_mode: nil,
        original_created_at: nil,
        inserted_at: ~U[2026-02-01 12:00:00Z],
        notebook: nil,
        tags: []
      }

      result = Backup.render_markdown(note, nil)

      refute result =~ "source_url"
      refute result =~ "clip_mode"
      refute result =~ "tags"
      assert result =~ ~s(title: "Simple")
      assert result =~ "Content"
    end

    test "renders empty body without crashing" do
      note = %Note{
        id: 3,
        title: "Empty",
        body: nil,
        source_url: nil,
        clip_mode: nil,
        original_created_at: nil,
        inserted_at: ~U[2026-02-01 12:00:00Z],
        notebook: nil,
        tags: []
      }

      result = Backup.render_markdown(note, nil)
      assert result =~ ~s(title: "Empty")
      assert result =~ "---"
    end
  end
end
