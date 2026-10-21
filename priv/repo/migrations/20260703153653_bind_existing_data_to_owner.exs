defmodule Librarian.Repo.Migrations.BindExistingDataToOwner do
  use Ecto.Migration

  @tables ~w(feeds read_states notebooks tags notes interactions
             interest_centroids affinities candidate_sources settings)

  def up do
    for table_name <- @tables do
      execute "ALTER TABLE #{table_name} ALTER COLUMN user_id SET NOT NULL"
    end
  end

  def down do
    for table_name <- @tables do
      execute "ALTER TABLE #{table_name} ALTER COLUMN user_id DROP NOT NULL"
    end
  end
end
