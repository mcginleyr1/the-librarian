defmodule Librarian.Stream.Interaction do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(open dwell like dislike save more_like less_like mute_source mute_topic done)

  def kinds, do: @kinds

  schema "interactions" do
    field :kind, :string
    field :value, :float
    field :dwell_ms, :integer
    field :occurred_at, :utc_datetime

    belongs_to :article, Librarian.Reader.Article
    belongs_to :user, Librarian.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(interaction, attrs) do
    interaction
    |> cast(attrs, [:article_id, :kind, :value, :dwell_ms, :occurred_at])
    |> validate_required([:article_id, :kind, :occurred_at])
    |> validate_inclusion(:kind, @kinds)
    |> assoc_constraint(:article)
  end
end
