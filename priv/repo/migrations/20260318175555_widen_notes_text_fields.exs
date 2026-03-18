defmodule Librarian.Repo.Migrations.WidenNotesTextFields do
  use Ecto.Migration

  def up do
    # Must drop generated columns before altering the columns they depend on,
    # then recreate them.

    execute "ALTER TABLE notes DROP COLUMN search_vector"
    execute "ALTER TABLE articles DROP COLUMN search_vector"

    alter table(:notes) do
      modify :title, :text
      modify :source_url, :text
    end

    alter table(:feeds) do
      modify :title, :text
      modify :site_url, :text
      modify :feed_url, :text
    end

    alter table(:articles) do
      modify :title, :text
      modify :url, :text
    end

    execute "ALTER TABLE notes ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(body, ''))) STORED"
    execute "CREATE INDEX notes_search_vector_idx ON notes USING gin(search_vector)"

    execute "ALTER TABLE articles ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(summary, ''))) STORED"
    execute "CREATE INDEX articles_search_vector_idx ON articles USING gin(search_vector)"
  end

  def down do
    execute "ALTER TABLE notes DROP COLUMN search_vector"
    execute "ALTER TABLE articles DROP COLUMN search_vector"

    alter table(:notes) do
      modify :title, :string
      modify :source_url, :string
    end

    alter table(:feeds) do
      modify :title, :string
      modify :site_url, :string
      modify :feed_url, :string
    end

    alter table(:articles) do
      modify :title, :string
      modify :url, :string
    end

    execute "ALTER TABLE notes ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(body, ''))) STORED"
    execute "CREATE INDEX notes_search_vector_idx ON notes USING gin(search_vector)"

    execute "ALTER TABLE articles ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(summary, ''))) STORED"
    execute "CREATE INDEX articles_search_vector_idx ON articles USING gin(search_vector)"
  end
end
