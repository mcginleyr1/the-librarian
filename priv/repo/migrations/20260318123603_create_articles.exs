defmodule Librarian.Repo.Migrations.CreateArticles do
  use Ecto.Migration

  def change do
    create table(:articles) do
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :guid, :string, null: false
      add :title, :string
      add :url, :string
      add :content, :text
      add :summary, :text
      add :author, :string
      add :published_at, :utc_datetime
      add :fetched_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:articles, [:feed_id, :guid])
    create index(:articles, [:feed_id])
    create index(:articles, [:published_at])

    execute(
      "ALTER TABLE articles ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(summary, ''))) STORED",
      "ALTER TABLE articles DROP COLUMN search_vector"
    )

    execute(
      "CREATE INDEX articles_search_vector_idx ON articles USING gin(search_vector)",
      "DROP INDEX articles_search_vector_idx"
    )
  end
end
