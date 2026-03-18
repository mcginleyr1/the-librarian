defmodule Librarian.Vault.Note do
  use Ecto.Schema
  import Ecto.Changeset

  @clip_modes ~w(selection full_article full_page pdf screenshot)

  schema "notes" do
    field :title, :string
    field :body, :string
    field :source_url, :string
    field :clip_mode, :string
    field :storage_key, :string
    field :evernote_guid, :string
    field :original_created_at, :utc_datetime

    belongs_to :notebook, Librarian.Vault.Notebook
    many_to_many :tags, Librarian.Vault.Tag, join_through: "note_tags", on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :title,
      :body,
      :source_url,
      :clip_mode,
      :storage_key,
      :notebook_id,
      :evernote_guid,
      :original_created_at
    ])
    |> validate_inclusion(:clip_mode, @clip_modes ++ [nil])
  end
end
