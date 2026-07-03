defmodule Librarian.Repo.Migrations.AddUserIdToOwnedTables do
  use Ecto.Migration

  # Articles are deliberately absent: they belong to a feed, and the feed
  # carries the ownership.
  @tables ~w(feeds read_states notebooks tags notes interactions
             interest_centroids affinities candidate_sources settings)a

  def change do
    for table_name <- @tables do
      alter table(table_name) do
        add :user_id, references(:users, on_delete: :delete_all)
      end

      create index(table_name, [:user_id])
    end
  end
end
