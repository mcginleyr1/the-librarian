defmodule Librarian.Workers.ExtractEdgesWorkerTest do
  use Librarian.DataCase, async: true

  alias Librarian.Vault
  alias Librarian.Workers.ExtractEdgesWorker

  @dims Librarian.Embeddings.dimensions()

  defp embedded_note!(title) do
    {:ok, note} = Vault.create_note(%{title: title, body: "body"})

    note
    |> Ecto.Changeset.change(embedding: Pgvector.new(List.duplicate(1.0, @dims)))
    |> Repo.update!()
  end

  test "cancels when the note has no embedding" do
    {:ok, note} = Vault.create_note(%{title: "bare"})

    assert {:cancel, :not_embedded} =
             ExtractEdgesWorker.perform(%Oban.Job{args: %{"note_id" => note.id}})
  end

  test "marks a note with no candidates as indexed without an API call" do
    note = embedded_note!("lonely")

    assert :ok = ExtractEdgesWorker.perform(%Oban.Job{args: %{"note_id" => note.id}})
    assert Repo.get!(Librarian.Vault.Note, note.id).graph_indexed_at != nil
  end

  test "cancels on missing API key so the job is not retried" do
    note = embedded_note!("first")
    _other = embedded_note!("second")

    assert {:cancel, :no_api_key} =
             ExtractEdgesWorker.perform(%Oban.Job{args: %{"note_id" => note.id}})

    assert Repo.get!(Librarian.Vault.Note, note.id).graph_indexed_at == nil
  end
end
