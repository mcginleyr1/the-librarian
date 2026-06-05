defmodule Librarian.Interest.Affinity do
  use Ecto.Schema
  import Ecto.Changeset

  schema "affinities" do
    field :kind, :string
    field :key, :string
    field :score, :float, default: 0.0

    timestamps(type: :utc_datetime)
  end

  def changeset(affinity, attrs) do
    affinity
    |> cast(attrs, [:kind, :key, :score])
    |> validate_required([:kind, :key, :score])
    |> unique_constraint([:kind, :key])
  end
end
