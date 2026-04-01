defmodule Librarian.Repo.Migrations.AddLastBackupAtToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :last_backup_at, :utc_datetime
    end
  end
end
