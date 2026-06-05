defmodule Librarian.Repo.Migrations.CreateDiscovery do
  use Ecto.Migration

  def change do
    create table(:candidate_sources) do
      add :domain, :string, null: false
      add :feed_url, :string
      add :channel, :string, null: false
      add :status, :string, default: "pending", null: false
      add :mention_count, :integer, default: 1, null: false
      add :sample_hit_rate, :float
      add :discovered_from_article_id, references(:articles, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:candidate_sources, [:domain])
    create index(:candidate_sources, [:status])

    alter table(:feeds) do
      add :origin, :string, default: "manual", null: false
      add :trust_score, :float, default: 0.5, null: false
      add :like_rate, :float
      add :discovered_at, :utc_datetime
    end
  end
end
