defmodule Librarian.Repo.Migrations.CreateReadStates do
  use Ecto.Migration

  def change do
    create table(:read_states) do
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :read_at, :utc_datetime
      add :starred, :boolean, default: false, null: false
      add :saved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:read_states, [:article_id])
    create index(:read_states, [:starred])
    create index(:read_states, [:saved_at])
  end
end
