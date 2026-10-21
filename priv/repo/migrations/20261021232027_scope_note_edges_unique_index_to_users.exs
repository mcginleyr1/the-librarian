defmodule Librarian.Repo.Migrations.ScopeNoteEdgesUniqueIndexToUsers do
  use Ecto.Migration

  def change do
    # Edges whose endpoints belong to another tenant were never reachable by
    # their owner and could shadow the real owner's edges on upsert.
    execute(
      """
      DELETE FROM note_edges e
      USING notes s, notes t
      WHERE e.source_note_id = s.id AND e.target_note_id = t.id
        AND (s.user_id <> e.user_id OR t.user_id <> e.user_id)
      """,
      ""
    )

    drop unique_index(:note_edges, [:source_note_id, :target_note_id, :kind])
    create unique_index(:note_edges, [:user_id, :source_note_id, :target_note_id, :kind])
  end
end
