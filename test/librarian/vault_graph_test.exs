defmodule Librarian.VaultGraphTest do
  use Librarian.DataCase, async: true

  alias Librarian.Vault
  alias Librarian.Vault.Edge

  @dims Librarian.Embeddings.dimensions()

  defp note!(title) do
    {:ok, note} = Vault.create_note(%{title: title, body: "body of #{title}"})
    note
  end

  defp embed!(note, components) do
    vector =
      Enum.reduce(components, List.duplicate(0.0, @dims), fn {i, v}, acc ->
        List.replace_at(acc, i, v)
      end)

    note
    |> Ecto.Changeset.change(embedding: Pgvector.new(vector))
    |> Repo.update!()
  end

  describe "generate_similarity_edges/1" do
    test "links similar notes and skips dissimilar ones" do
      a = note!("A") |> embed!(%{0 => 1.0})
      b = note!("B") |> embed!(%{0 => 0.9, 1 => 0.1})
      _c = note!("C") |> embed!(%{2 => 1.0})

      assert {:ok, count} = Vault.generate_similarity_edges()
      assert count == 2

      related = Vault.related_notes(a.id)
      assert [%{edge: edge, note: other}] = related
      assert other.id == b.id
      assert edge.kind == "related"
      assert edge.origin == "similarity"
      assert edge.weight > 0.9
    end

    test "scopes to one note with :note_id" do
      a = note!("A") |> embed!(%{0 => 1.0})
      _b = note!("B") |> embed!(%{0 => 1.0})

      assert {:ok, 1} = Vault.generate_similarity_edges(note_id: a.id)
    end
  end

  describe "upsert_edges/1" do
    test "inserts valid edges and updates on conflict" do
      a = note!("A")
      b = note!("B")

      entry = %{
        source_note_id: a.id,
        target_note_id: b.id,
        kind: "extends",
        reason: "first",
        weight: 0.5,
        origin: "llm"
      }

      assert {1, _} = Vault.upsert_edges([entry])
      assert {1, _} = Vault.upsert_edges([%{entry | reason: "second", weight: 0.9}])

      assert [%{edge: edge}] = Vault.related_notes(a.id)
      assert edge.reason == "second"
      assert edge.weight == 0.9
    end

    test "rejects unknown kinds and self-edges" do
      a = note!("A")
      b = note!("B")

      entries = [
        %{
          source_note_id: a.id,
          target_note_id: b.id,
          kind: "bogus",
          reason: nil,
          weight: 1.0,
          origin: "llm"
        },
        %{
          source_note_id: a.id,
          target_note_id: a.id,
          kind: "extends",
          reason: nil,
          weight: 1.0,
          origin: "llm"
        }
      ]

      assert {0, _} = Vault.upsert_edges(entries)
      assert Vault.related_notes(a.id) == []
    end
  end

  describe "related_notes/1" do
    test "includes edges from both directions and dedupes per kind" do
      a = note!("A")
      b = note!("B")

      Vault.upsert_edges([
        %{
          source_note_id: a.id,
          target_note_id: b.id,
          kind: "related",
          reason: nil,
          weight: 0.8,
          origin: "similarity"
        },
        %{
          source_note_id: b.id,
          target_note_id: a.id,
          kind: "related",
          reason: nil,
          weight: 0.8,
          origin: "similarity"
        },
        %{
          source_note_id: b.id,
          target_note_id: a.id,
          kind: "extends",
          reason: "b builds on a",
          weight: 0.7,
          origin: "llm"
        }
      ])

      related = Vault.related_notes(a.id)
      assert length(related) == 2
      assert Enum.all?(related, &(&1.note.id == b.id))
      assert Enum.map(related, & &1.edge.kind) |> Enum.sort() == ["extends", "related"]
    end
  end

  test "delete_edge/1 removes the edge" do
    a = note!("A")
    b = note!("B")

    Vault.upsert_edges([
      %{
        source_note_id: a.id,
        target_note_id: b.id,
        kind: "extends",
        reason: nil,
        weight: 1.0,
        origin: "llm"
      }
    ])

    [%{edge: edge}] = Vault.related_notes(a.id)
    assert :ok = Vault.delete_edge(edge.id)
    assert Vault.related_notes(a.id) == []
  end

  describe "annotations" do
    test "create, list, delete" do
      note = note!("A")

      assert {:ok, annotation} = Vault.create_annotation(note.id, "a thought")
      assert [%{body: "a thought"}] = Vault.list_annotations(note.id)

      assert :ok = Vault.delete_annotation(annotation.id)
      assert Vault.list_annotations(note.id) == []
    end

    test "rejects empty body" do
      note = note!("A")
      assert {:error, _changeset} = Vault.create_annotation(note.id, "")
    end
  end

  test "mark_graph_stale/1 clears graph_indexed_at" do
    note = note!("A")

    note
    |> Ecto.Changeset.change(graph_indexed_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert :ok = Vault.mark_graph_stale(note.id)
    assert Repo.get!(Librarian.Vault.Note, note.id).graph_indexed_at == nil
  end

  describe "graph/0" do
    test "returns connected notes with degrees and their edges" do
      a = note!("A")
      b = note!("B")
      _isolated = note!("C")

      Vault.upsert_edges([
        %{
          source_note_id: a.id,
          target_note_id: b.id,
          kind: "extends",
          reason: nil,
          weight: 0.8,
          origin: "llm"
        }
      ])

      %{nodes: nodes, edges: edges} = Vault.graph()

      assert Enum.map(nodes, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert Enum.all?(nodes, &(&1.degree == 1))
      assert [%{kind: "extends", source: source, target: target}] = edges
      assert {source, target} == {a.id, b.id}
    end
  end

  describe "duplicate notes" do
    test "import skips exact duplicates without a guid" do
      {:ok, first} = Vault.create_note_from_import(%{title: "Once", body: "b"}, [])
      {:ok, second} = Vault.create_note_from_import(%{title: "Once", body: "b"}, [])

      assert second.id == first.id

      assert Repo.aggregate(from(n in Librarian.Vault.Note, where: n.title == "Once"), :count) ==
               1
    end

    test "dedupe_notes/0 keeps the oldest copy and moves annotations over" do
      {:ok, keeper} = Vault.create_note_from_import(%{title: "Dup", body: "same"}, [])

      # bypass import-time prevention to simulate a pre-existing duplicate
      {:ok, copy} =
        %Librarian.Vault.Note{user_id: Librarian.Accounts.owner!().id}
        |> Librarian.Vault.Note.changeset(%{title: "Dup", body: "same"})
        |> Repo.insert()

      {:ok, _} = Vault.create_annotation(copy.id, "keep me")

      assert Vault.duplicate_note_count() == 1
      assert Vault.dedupe_notes() == 1
      assert Vault.duplicate_note_count() == 0

      assert Repo.get(Librarian.Vault.Note, copy.id) == nil
      assert [%{body: "keep me"}] = Vault.list_annotations(keeper.id)
      assert Repo.get!(Librarian.Vault.Note, keeper.id).graph_indexed_at == nil
    end
  end

  test "edge changeset validates kind and origin" do
    changeset =
      Edge.changeset(%Edge{}, %{kind: "nope", origin: "llm", source_note_id: 1, target_note_id: 2})

    refute changeset.valid?

    changeset =
      Edge.changeset(%Edge{}, %{
        kind: "extends",
        origin: "llm",
        source_note_id: 1,
        target_note_id: 2
      })

    assert changeset.valid?
  end
end
