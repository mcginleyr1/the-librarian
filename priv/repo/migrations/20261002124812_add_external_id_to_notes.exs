defmodule Librarian.Repo.Migrations.AddExternalIdToNotes do
  use Ecto.Migration

  # A stable id owned by an editor client (e.g. an org-roam node UUID), so
  # two-way sync can upsert without knowing our integer ids.
  def change do
    alter table(:notes) do
      add :external_id, :string
    end

    create unique_index(:notes, [:user_id, :external_id], where: "external_id IS NOT NULL")
  end
end
