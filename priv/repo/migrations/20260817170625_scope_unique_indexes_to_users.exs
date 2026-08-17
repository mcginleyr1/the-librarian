defmodule Librarian.Repo.Migrations.ScopeUniqueIndexesToUsers do
  use Ecto.Migration

  # These uniques predate multi-tenancy and were global: the first tenant to
  # use a domain/tag/notebook name "owned" it, corrupting or crashing every
  # other tenant's writes. Scope them per user.

  def up do
    drop unique_index(:candidate_sources, [:domain])
    create unique_index(:candidate_sources, [:user_id, :domain])

    drop unique_index(:tags, [:name])
    create unique_index(:tags, [:user_id, :name])

    drop unique_index(:notebooks, [:name])
    create unique_index(:notebooks, [:user_id, :name])

    drop unique_index(:affinities, [:kind, :key])
    create unique_index(:affinities, [:user_id, :kind, :key])
  end

  def down do
    drop unique_index(:affinities, [:user_id, :kind, :key])
    create unique_index(:affinities, [:kind, :key])

    drop unique_index(:notebooks, [:user_id, :name])
    create unique_index(:notebooks, [:name])

    drop unique_index(:tags, [:user_id, :name])
    create unique_index(:tags, [:name])

    drop unique_index(:candidate_sources, [:user_id, :domain])
    create unique_index(:candidate_sources, [:domain])
  end
end
