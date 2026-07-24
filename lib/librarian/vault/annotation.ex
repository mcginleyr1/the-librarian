defmodule Librarian.Vault.Annotation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "annotations" do
    field :body, :string

    belongs_to :note, Librarian.Vault.Note
    belongs_to :user, Librarian.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(annotation, attrs) do
    annotation
    |> cast(attrs, [:body, :note_id])
    |> validate_required([:body, :note_id])
    |> validate_length(:body, min: 1, max: 10_000)
  end
end
