defmodule Librarian.Repo.Migrations.AddEmbeddings do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    alter table(:articles) do
      add :embedding, :vector, size: 384
    end

    alter table(:notes) do
      add :embedding, :vector, size: 384
    end
  end

  def down do
    alter table(:articles), do: remove(:embedding)
    alter table(:notes), do: remove(:embedding)
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
