defmodule Librarian.Repo.Migrations.BindExistingDataToOwner do
  use Ecto.Migration

  @owner_email "owner@example.com"

  @tables ~w(feeds read_states notebooks tags notes interactions
             interest_centroids affinities candidate_sources settings)

  def up do
    execute """
    INSERT INTO users (email, name, provider, inserted_at, updated_at)
    VALUES ('#{@owner_email}', 'Rob McGinley', 'google', now(), now())
    ON CONFLICT (email) DO NOTHING
    """

    for table_name <- @tables do
      execute """
      UPDATE #{table_name}
      SET user_id = (SELECT id FROM users WHERE email = '#{@owner_email}')
      WHERE user_id IS NULL
      """

      execute "ALTER TABLE #{table_name} ALTER COLUMN user_id SET NOT NULL"
    end
  end

  def down do
    for table_name <- @tables do
      execute "ALTER TABLE #{table_name} ALTER COLUMN user_id DROP NOT NULL"
    end
  end
end
