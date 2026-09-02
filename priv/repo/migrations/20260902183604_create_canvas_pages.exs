defmodule Librarian.Repo.Migrations.CreateCanvasPages do
  use Ecto.Migration

  def change do
    create table(:canvas_pages) do
      add :title, :string, null: false
      add :doc, :map, null: false, default: %{}
      add :root_note_id, references(:notes, on_delete: :nilify_all)
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:canvas_pages, [:user_id])
    create index(:canvas_pages, [:root_note_id])
  end
end
