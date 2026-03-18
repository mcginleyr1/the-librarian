defmodule Librarian.Vault.Notebook do
  use Ecto.Schema
  import Ecto.Changeset

  schema "notebooks" do
    field :name, :string
    field :description, :string

    has_many :notes, Librarian.Vault.Note

    timestamps(type: :utc_datetime)
  end

  def changeset(notebook, attrs) do
    notebook
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
