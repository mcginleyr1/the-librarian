defmodule Librarian.Repo.Migrations.AddFetchIntervalsAndCategoryOrder do
  use Ecto.Migration

  def change do
    alter table(:feeds) do
      add :fetch_interval_minutes, :integer, null: false, default: 120
    end

    alter table(:settings) do
      add :category_order, {:array, :string}, null: false, default: []
      add :pinned_lenses, {:array, :string}, null: false, default: []
    end

    create index(:articles, [:fetched_at])
  end
end
