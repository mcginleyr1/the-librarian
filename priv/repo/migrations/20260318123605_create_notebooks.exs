defmodule Librarian.Repo.Migrations.CreateNotebooks do
  use Ecto.Migration

  def change do
    create table(:notebooks) do
      add :name, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:notebooks, [:name])
  end
end
