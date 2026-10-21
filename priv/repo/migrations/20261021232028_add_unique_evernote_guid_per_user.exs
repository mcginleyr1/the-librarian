defmodule Librarian.Repo.Migrations.AddUniqueEvernoteGuidPerUser do
  use Ecto.Migration

  def change do
    drop index(:notes, [:evernote_guid])

    create unique_index(:notes, [:user_id, :evernote_guid],
             where: "evernote_guid IS NOT NULL",
             name: :notes_user_id_evernote_guid_index
           )
  end
end
