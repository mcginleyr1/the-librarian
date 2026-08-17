defmodule Librarian.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  # Shared-catalog split: feeds/articles become a global catalog fetched once,
  # and everything per-user about a feed (category, active, discovery state)
  # moves to a subscriptions join table.

  def up do
    create table(:subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :category, :string
      add :active, :boolean, default: true, null: false
      add :origin, :string, default: "manual", null: false
      add :trust_score, :float, default: 0.5
      add :like_rate, :float
      add :discovered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subscriptions, [:user_id, :feed_id])
    create index(:subscriptions, [:feed_id])

    execute """
    INSERT INTO subscriptions
      (user_id, feed_id, category, active, origin, trust_score, like_rate,
       discovered_at, inserted_at, updated_at)
    SELECT user_id, id, category, active, origin, trust_score, like_rate,
           discovered_at, now(), now()
    FROM feeds
    """

    alter table(:feeds) do
      remove :user_id
      remove :category
      remove :active
      remove :origin
      remove :trust_score
      remove :like_rate
      remove :discovered_at
    end
  end

  def down do
    alter table(:feeds) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :category, :string
      add :active, :boolean, default: true, null: false
      add :origin, :string, default: "manual"
      add :trust_score, :float, default: 0.5
      add :like_rate, :float
      add :discovered_at, :utc_datetime
    end

    execute """
    UPDATE feeds f
    SET user_id = s.user_id, category = s.category, active = s.active,
        origin = s.origin, trust_score = s.trust_score, like_rate = s.like_rate,
        discovered_at = s.discovered_at
    FROM subscriptions s
    WHERE s.feed_id = f.id
    """

    create index(:feeds, [:user_id])

    drop table(:subscriptions)
  end
end
