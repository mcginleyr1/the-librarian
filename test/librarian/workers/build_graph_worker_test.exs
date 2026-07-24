defmodule Librarian.Workers.BuildGraphWorkerTest do
  use Librarian.DataCase, async: true
  use Oban.Testing, repo: Librarian.Repo

  alias Librarian.{Settings, Vault}
  alias Librarian.Workers.{BuildGraphWorker, ExtractEdgesWorker}

  @dims Librarian.Embeddings.dimensions()

  defp embedded_note!(title) do
    {:ok, note} = Vault.create_note(%{title: title, body: "body"})

    note
    |> Ecto.Changeset.change(embedding: Pgvector.new(List.duplicate(1.0, @dims)))
    |> Repo.update!()
  end

  test "builds similarity edges; no LLM jobs without an API key" do
    a = embedded_note!("first")
    _b = embedded_note!("second")

    assert :ok = perform_job(BuildGraphWorker, %{})

    assert [%{edge: %{origin: "similarity"}}] = Vault.related_notes(a.id)
    refute_enqueued(worker: ExtractEdgesWorker)
  end

  test "enqueues extraction for unindexed embedded notes when configured" do
    {:ok, _} = Settings.save_settings(%{"anthropic_api_key" => "sk-test"})
    note = embedded_note!("first")

    assert :ok = perform_job(BuildGraphWorker, %{})

    assert_enqueued(worker: ExtractEdgesWorker, args: %{note_id: note.id})
  end
end
