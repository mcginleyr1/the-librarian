defmodule Librarian.Reader.Article do
  use Ecto.Schema
  import Ecto.Changeset

  schema "articles" do
    field :guid, :string
    field :title, :string
    field :url, :string
    field :content, :string
    field :summary, :string
    field :author, :string
    field :published_at, :utc_datetime
    field :fetched_at, :utc_datetime

    belongs_to :feed, Librarian.Reader.Feed
    has_one :read_state, Librarian.Reader.ReadState

    timestamps(type: :utc_datetime)
  end

  def changeset(article, attrs) do
    article
    |> cast(attrs, [
      :feed_id,
      :guid,
      :title,
      :url,
      :content,
      :summary,
      :author,
      :published_at,
      :fetched_at
    ])
    |> validate_required([:feed_id, :guid, :fetched_at])
    |> unique_constraint([:feed_id, :guid])
  end
end
