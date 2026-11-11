defmodule Librarian.Repo.Migrations.AddUrlIndexToArticles do
  use Ecto.Migration

  # Hash, not btree: equality is all clip lookups need, and a btree would
  # reject any feed article whose URL exceeds its ~2.7KB row limit.
  def change do
    create index(:articles, [:url], using: :hash)
  end
end
