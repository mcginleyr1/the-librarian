defmodule Librarian.Repo.Migrations.TruncateNotesTsvector do
  use Ecto.Migration

  def up do
    # Large clipped pages exceed PostgreSQL's 1MB tsvector limit.
    # Truncate body to 100K chars before vectorizing — ample for search.
    execute "ALTER TABLE notes DROP COLUMN search_vector"

    execute """
    ALTER TABLE notes ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (
        to_tsvector('english',
          coalesce(title, '') || ' ' ||
          left(coalesce(body, ''), 100000)
        )
      ) STORED
    """

    execute "CREATE INDEX notes_search_vector_idx ON notes USING gin(search_vector)"
  end

  def down do
    execute "DROP INDEX notes_search_vector_idx"
    execute "ALTER TABLE notes DROP COLUMN search_vector"

    execute """
    ALTER TABLE notes ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (
        to_tsvector('english', coalesce(title, '') || ' ' || coalesce(body, ''))
      ) STORED
    """

    execute "CREATE INDEX notes_search_vector_idx ON notes USING gin(search_vector)"
  end
end
