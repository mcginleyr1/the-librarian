defmodule Librarian.Repo.Migrations.AddFeedIdIdIndexToArticles do
  use Ecto.Migration

  # Lets unread counts and the unread list find article ids per feed with an
  # index-only scan instead of reading the whole articles heap.
  def change do
    create index(:articles, [:feed_id, :id])
  end
end
