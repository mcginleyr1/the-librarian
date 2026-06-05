defmodule Librarian.Repo.Migrations.AddArticleTags do
  use Ecto.Migration

  def change do
    alter table(:articles) do
      add :topics, {:array, :string}, default: [], null: false
      add :entities, {:array, :map}, default: [], null: false
      add :content_type, :string
      add :depth_score, :float
      add :judge_score, :float
      add :tagged_at, :utc_datetime
    end

    create index(:articles, [:topics], using: :gin)
    create index(:articles, [:tagged_at])
  end
end
