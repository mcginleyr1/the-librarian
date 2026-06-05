defmodule Librarian.Repo.Migrations.CreateInteractions do
  use Ecto.Migration

  def change do
    create table(:interactions) do
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :value, :float
      add :dwell_ms, :integer
      add :occurred_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:interactions, [:article_id])
    create index(:interactions, [:kind])
  end
end
