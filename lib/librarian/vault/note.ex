defmodule Librarian.Vault.Note do
  use Ecto.Schema
  import Ecto.Changeset

  @clip_modes ~w(selection full_article full_page pdf screenshot image markdown)

  schema "notes" do
    field :title, :string
    field :body, :string
    field :source_url, :string
    field :clip_mode, :string
    field :storage_key, :string
    field :evernote_guid, :string
    field :external_id, :string
    field :original_created_at, :utc_datetime
    field :embedding, Pgvector.Ecto.Vector
    field :graph_indexed_at, :utc_datetime

    belongs_to :notebook, Librarian.Vault.Notebook
    belongs_to :user, Librarian.Accounts.User
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

  @doc """
  Changeset for notes synced from an editor client — the only path that sets
  `external_id` (the client's stable id, e.g. an org-roam UUID). Synced notes
  are markdown and must have a title.
  """
  def sync_changeset(note, attrs, external_id) do
    note
    |> changeset(attrs)
    |> put_change(:external_id, external_id)
    |> put_change(:clip_mode, "markdown")
    |> validate_required([:title])
    |> unique_constraint(:external_id, name: :notes_user_id_external_id_index)
  end
end
