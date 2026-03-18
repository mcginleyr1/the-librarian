defmodule Librarian.Reader.ReadState do
  use Ecto.Schema
  import Ecto.Changeset

  schema "read_states" do
    field :read_at, :utc_datetime
    field :starred, :boolean, default: false
    field :saved_at, :utc_datetime

    belongs_to :article, Librarian.Reader.Article

    timestamps(type: :utc_datetime)
  end

  def changeset(read_state, attrs) do
    read_state
    |> cast(attrs, [:article_id, :read_at, :starred, :saved_at])
    |> validate_required([:article_id])
    |> unique_constraint(:article_id)
  end
end
