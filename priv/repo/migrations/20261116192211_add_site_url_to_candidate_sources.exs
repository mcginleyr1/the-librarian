defmodule Librarian.Repo.Migrations.AddSiteUrlToCandidateSources do
  use Ecto.Migration

  # The site as it was supplied (a followed URL can carry a path), kept beside
  # the bare domain that candidates are deduplicated on.
  def change do
    alter table(:candidate_sources) do
      add :site_url, :text
    end
  end
end
