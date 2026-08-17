defmodule Librarian.Repo.Migrations.AddTenancyInfrastructure do
  use Ecto.Migration

  def up do
    # read_states: one row per (user, article), not per article
    drop unique_index(:read_states, [:article_id])
    create unique_index(:read_states, [:user_id, :article_id])

    # settings: one row per user, not a singleton (a plain index on user_id
    # already exists from AddUserIdToOwnedTables, hence the explicit name)
    create unique_index(:settings, [:user_id], name: :settings_user_id_unique_index)

    # llm_usage: per-tenant metering
    alter table(:llm_usage) do
      add :user_id, references(:users, on_delete: :delete_all)
    end

    execute """
    UPDATE llm_usage SET user_id = (SELECT id FROM users ORDER BY id LIMIT 1)
    WHERE user_id IS NULL
    """

    execute "ALTER TABLE llm_usage ALTER COLUMN user_id SET NOT NULL"
    create index(:llm_usage, [:user_id])

    # users: bearer token for the clip API
    alter table(:users) do
      add :api_token, :string
    end

    create unique_index(:users, [:api_token])
  end

  def down do
    drop unique_index(:users, [:api_token])

    alter table(:users) do
      remove :api_token
    end

    drop index(:llm_usage, [:user_id])

    alter table(:llm_usage) do
      remove :user_id
    end

    drop unique_index(:settings, [:user_id], name: :settings_user_id_unique_index)

    drop unique_index(:read_states, [:user_id, :article_id])
    create unique_index(:read_states, [:article_id])
  end
end
