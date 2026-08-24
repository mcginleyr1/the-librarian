defmodule Librarian.Vault.Edge do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(related extends contradicts example_of references same_topic)
  @origins ~w(similarity llm user wikilink)

  schema "note_edges" do
    field :kind, :string
    field :reason, :string
    field :weight, :float, default: 1.0
    field :origin, :string

    belongs_to :source_note, Librarian.Vault.Note
    belongs_to :target_note, Librarian.Vault.Note
    belongs_to :user, Librarian.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:kind, :reason, :weight, :origin, :source_note_id, :target_note_id])
    |> validate_required([:kind, :origin, :source_note_id, :target_note_id])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:origin, @origins)
  end
end
