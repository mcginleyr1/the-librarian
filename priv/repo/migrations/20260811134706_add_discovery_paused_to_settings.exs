defmodule Librarian.Repo.Migrations.AddDiscoveryPausedToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :discovery_paused, :boolean, default: false, null: false
    end
  end
end
