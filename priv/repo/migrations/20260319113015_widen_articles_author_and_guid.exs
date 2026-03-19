defmodule Librarian.Repo.Migrations.WidenArticlesAuthorAndGuid do
  use Ecto.Migration

  def change do
    alter table(:articles) do
      modify :guid, :text, null: false
      modify :author, :text
    end
  end
end
