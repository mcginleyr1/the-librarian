defmodule Librarian.Repo.Migrations.AddIntentQueryToCandidateSources do
  use Ecto.Migration

  def change do
    alter table(:candidate_sources) do
      add :intent_query, :string
    end
  end
end
