defmodule Librarian.VaultTest do
  use Librarian.DataCase, async: true

  alias Librarian.Vault
  alias Librarian.Vault.{Note, Notebook, Tag}

  defp notebook_attrs(overrides \\ %{}) do
    Map.merge(%{name: "Notebook #{:rand.uniform(999_999)}"}, overrides)
  end

  describe "create_notebook/1" do
    test "creates a notebook" do
      assert {:ok, %Notebook{} = nb} = Vault.create_notebook(%{name: "Research"})
      assert nb.name == "Research"
    end

    test "rejects duplicate name" do
      Vault.create_notebook(%{name: "Unique"})
      assert {:error, changeset} = Vault.create_notebook(%{name: "Unique"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "create_note/2" do
    setup do
      {:ok, notebook} = Vault.create_notebook(notebook_attrs())
      %{notebook: notebook}
    end

    test "creates a note with body", %{notebook: nb} do
      assert {:ok, %Note{} = note} =
               Vault.create_note(%{title: "My Note", body: "some content", notebook_id: nb.id})

      assert note.title == "My Note"
      assert note.body == "some content"
    end

    test "creates a note with tags", %{notebook: nb} do
      assert {:ok, note} =
               Vault.create_note(%{title: "Tagged", notebook_id: nb.id}, ["elixir", "otp"])

      assert length(note.tags) == 2
      tag_names = Enum.map(note.tags, & &1.name)
      assert "elixir" in tag_names
      assert "otp" in tag_names
    end

    test "tags are lowercased and trimmed" do
      {:ok, note} = Vault.create_note(%{title: "Tags"}, ["  Elixir  ", "OTP"])
      tag_names = Enum.map(note.tags, & &1.name)
      assert "elixir" in tag_names
      assert "otp" in tag_names
    end

    test "duplicate tag names reuse existing tag" do
      Vault.create_note(%{title: "First"}, ["elixir"])
      {:ok, note} = Vault.create_note(%{title: "Second"}, ["elixir"])

      tag_names = Enum.map(note.tags, & &1.name)
      assert tag_names == ["elixir"]
      assert Repo.aggregate(Tag, :count) == 1
    end
  end

  describe "search/1" do
    setup do
      {:ok, n1} =
        Vault.create_note(%{title: "Elixir GenServers", body: "OTP processes are great"})

      {:ok, n2} = Vault.create_note(%{title: "PostgreSQL tuning", body: "Index your queries"})
      {:ok, _n3} = Vault.create_note(%{title: "Unrelated note", body: "nothing here"})
      %{n1: n1, n2: n2}
    end

    test "finds notes matching title" do
      results = Vault.search("Elixir")
      ids = Enum.map(results, & &1.id)
      assert length(results) >= 1
      assert Enum.any?(ids, fn id -> id end)
    end

    test "finds notes matching body content" do
      results = Vault.search("PostgreSQL")
      assert length(results) >= 1
    end

    test "returns empty list for no matches" do
      results = Vault.search("xyzzy_no_match_ever")
      assert results == []
    end
  end

  describe "update_note/3" do
    test "updates title and body" do
      {:ok, note} = Vault.create_note(%{title: "Old", body: "old content"})
      assert {:ok, updated} = Vault.update_note(note, %{title: "New", body: "new content"})
      assert updated.title == "New"
    end

    test "replaces tags when provided" do
      {:ok, note} = Vault.create_note(%{title: "Note"}, ["old-tag"])
      {:ok, updated} = Vault.update_note(note, %{}, ["new-tag"])
      tag_names = Enum.map(updated.tags, & &1.name)
      assert tag_names == ["new-tag"]
      refute "old-tag" in tag_names
    end
  end

  describe "delete_note/1" do
    test "removes the note" do
      {:ok, note} = Vault.create_note(%{title: "Temporary"})
      assert {:ok, _} = Vault.delete_note(note)
      assert_raise Ecto.NoResultsError, fn -> Vault.get_note!(note.id) end
    end
  end
end
