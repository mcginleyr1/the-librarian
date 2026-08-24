defmodule Librarian.VaultWikilinksTest do
  use Librarian.DataCase, async: true

  alias Librarian.Vault
  alias Librarian.Vault.Edge

  defp edges_from(note_id) do
    Repo.all(from e in Edge, where: e.source_note_id == ^note_id)
  end

  describe "wikilink edge sync" do
    test "creating a note with [[Title]] links creates a wikilink references edge" do
      {:ok, target} = Vault.create_note(%{title: "OTP Supervision", body: "trees"})
      {:ok, note} = Vault.create_note(%{title: "Source", body: "see [[OTP Supervision]]"})

      assert [edge] = edges_from(note.id)
      assert edge.target_note_id == target.id
      assert edge.kind == "references"
      assert edge.origin == "wikilink"
    end

    test "titles resolve case-insensitively" do
      {:ok, target} = Vault.create_note(%{title: "GenServer Basics", body: "x"})
      {:ok, note} = Vault.create_note(%{title: "S", body: "[[genserver basics]]"})

      assert [edge] = edges_from(note.id)
      assert edge.target_note_id == target.id
    end

    test "unresolved titles create no edges" do
      {:ok, note} = Vault.create_note(%{title: "S", body: "[[No Such Note]]"})
      assert edges_from(note.id) == []
    end

    test "self-links are ignored" do
      {:ok, note} = Vault.create_note(%{title: "Recursive", body: "I link [[Recursive]]"})
      assert edges_from(note.id) == []
    end

    test "removing a link from the body removes only the wikilink edge" do
      {:ok, _target} = Vault.create_note(%{title: "Target", body: "x"})
      {:ok, other} = Vault.create_note(%{title: "Other", body: "y"})
      {:ok, note} = Vault.create_note(%{title: "S", body: "[[Target]]"})
      :ok = Vault.link_notes(note.id, other.id, "extends")

      {:ok, note} = Vault.update_note(note, %{body: "no more links"})

      assert [edge] = edges_from(note.id)
      assert edge.origin == "user"
      assert edge.target_note_id == other.id
    end

    test "editing keeps existing links and adds new ones" do
      {:ok, a} = Vault.create_note(%{title: "Note A", body: "x"})
      {:ok, b} = Vault.create_note(%{title: "Note B", body: "y"})
      {:ok, note} = Vault.create_note(%{title: "S", body: "[[Note A]]"})

      {:ok, note} = Vault.update_note(note, %{body: "[[Note A]] and [[Note B]]"})

      targets = edges_from(note.id) |> Enum.map(& &1.target_note_id) |> Enum.sort()
      assert targets == Enum.sort([a.id, b.id])
    end
  end

  describe "wikilink_targets/1" do
    test "maps downcased titles to note ids" do
      {:ok, target} = Vault.create_note(%{title: "Distributed Systems", body: "x"})

      assert Vault.wikilink_targets("reading [[Distributed Systems]] today") ==
               %{"distributed systems" => target.id}
    end

    test "returns empty map when body has no links" do
      assert Vault.wikilink_targets("plain text") == %{}
      assert Vault.wikilink_targets(nil) == %{}
    end
  end

  describe "suggest_notes/2" do
    test "matches title substrings case-insensitively" do
      {:ok, hit} = Vault.create_note(%{title: "Elixir Metaprogramming", body: "x"})
      {:ok, _miss} = Vault.create_note(%{title: "Postgres Tuning", body: "y"})

      assert [%{id: id}] = Vault.suggest_notes("metapro")
      assert id == hit.id
    end

    test "empty query returns recent titled notes" do
      {:ok, _} = Vault.create_note(%{title: "One", body: "x"})
      {:ok, _} = Vault.create_note(%{title: "Two", body: "y"})

      titles = Vault.suggest_notes("") |> Enum.map(& &1.title)
      assert "One" in titles
      assert "Two" in titles
    end

    test "respects the limit" do
      for i <- 1..5, do: Vault.create_note(%{title: "Note #{i}", body: "x"})
      assert length(Vault.suggest_notes("note", limit: 3)) == 3
    end
  end

  describe "unlinked_mentions/2" do
    test "finds notes mentioning the title without an edge" do
      {:ok, note} = Vault.create_note(%{title: "Raft Consensus", body: "the algorithm"})

      {:ok, mentioner} =
        Vault.create_note(%{title: "Reading list", body: "study raft consensus soon"})

      assert [found] = Vault.unlinked_mentions(note)
      assert found.id == mentioner.id
    end

    test "excludes notes already connected by any edge" do
      {:ok, note} = Vault.create_note(%{title: "Raft Consensus", body: "the algorithm"})
      {:ok, linked} = Vault.create_note(%{title: "L", body: "raft consensus notes"})
      :ok = Vault.link_notes(linked.id, note.id)

      assert Vault.unlinked_mentions(note) == []
    end

    test "wikilinked mentions don't show up (already edges)" do
      {:ok, note} = Vault.create_note(%{title: "Raft Consensus", body: "the algorithm"})
      {:ok, _} = Vault.create_note(%{title: "W", body: "see [[Raft Consensus]]"})

      assert Vault.unlinked_mentions(note) == []
    end

    test "skips trivially short titles" do
      {:ok, note} = Vault.create_note(%{title: "AI", body: "x"})
      {:ok, _} = Vault.create_note(%{title: "M", body: "ai everywhere"})

      assert Vault.unlinked_mentions(note) == []
    end
  end

  describe "link_notes/3" do
    test "creates a user-origin edge visible in related_notes" do
      {:ok, a} = Vault.create_note(%{title: "A", body: "x"})
      {:ok, b} = Vault.create_note(%{title: "B", body: "y"})

      :ok = Vault.link_notes(a.id, b.id)

      assert [%{edge: edge, note: other}] = Vault.related_notes(a.id)
      assert edge.origin == "user"
      assert edge.kind == "references"
      assert other.id == b.id
    end
  end
end
