defmodule Librarian.Repo.Migrations.CreateNotes do
  use Ecto.Migration

  def change do
    create table(:notes) do
      add :title, :string
      add :body, :text
      add :source_url, :string
      add :clip_mode, :string
      add :storage_key, :string
      add :notebook_id, references(:notebooks, on_delete: :nilify_all)
      add :evernote_guid, :string
      add :original_created_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create table(:note_tags, primary_key: false) do
      add :note_id, references(:notes, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, on_delete: :delete_all), null: false
    end

    create unique_index(:note_tags, [:note_id, :tag_id])
    create index(:notes, [:notebook_id])
    create index(:notes, [:clip_mode])
    create index(:notes, [:evernote_guid])

    execute(
      "ALTER TABLE notes ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(body, ''))) STORED",
      "ALTER TABLE notes DROP COLUMN search_vector"
    )

    execute(
      "CREATE INDEX notes_search_vector_idx ON notes USING gin(search_vector)",
      "DROP INDEX notes_search_vector_idx"
    )
  end
end
