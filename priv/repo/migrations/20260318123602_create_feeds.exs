defmodule Librarian.Repo.Migrations.CreateFeeds do
  use Ecto.Migration

  def change do
    create table(:feeds) do
      add :title, :string, null: false
      add :site_url, :string
      add :feed_url, :string, null: false
      add :category, :string
      add :etag, :string
      add :last_modified, :string
      add :last_fetched_at, :utc_datetime
      add :fetch_error, :text
      add :active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feeds, [:feed_url])
    create index(:feeds, [:category])
    create index(:feeds, [:active])
  end
end
