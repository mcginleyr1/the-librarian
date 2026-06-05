defmodule Librarian.Interest.Centroid do
  use Ecto.Schema

  schema "interest_centroids" do
    field :label, :string
    field :embedding, Pgvector.Ecto.Vector
    field :weight, :float, default: 1.0
    field :member_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
