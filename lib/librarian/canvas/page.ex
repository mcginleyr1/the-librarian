defmodule Librarian.Canvas.Page do
  @moduledoc """
  A composition page: a JSON Canvas 1.0 document of cards and connectors laid
  out over vault notes. `doc` holds `"nodes"` and `"edges"` exactly as the
  format specifies; note cards are file nodes whose `file` is `"note:<id>"`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "canvas_pages" do
    field :title, :string
    field :doc, :map, default: %{"nodes" => [], "edges" => []}

    belongs_to :root_note, Librarian.Vault.Note
    belongs_to :user, Librarian.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(page, attrs) do
    page
    |> cast(attrs, [:title, :doc, :root_note_id])
    |> validate_required([:title])
    |> validate_length(:title, max: 200)
  end
end
