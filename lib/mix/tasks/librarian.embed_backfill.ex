defmodule Mix.Tasks.Librarian.EmbedBackfill do
  @shortdoc "Backfill embeddings for vault notes and articles that lack them"
  @moduledoc """
  Embeds every note and article without an embedding using the local Ollama model.

      mix librarian.embed_backfill

  Safe to re-run: only rows where `embedding IS NULL` are processed.
  """
  use Mix.Task

  import Ecto.Query

  alias Librarian.{Embeddings, Repo}
  alias Librarian.Reader.Article
  alias Librarian.Vault.Note

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    notes = backfill(Note, fn n -> text([n.title, n.body]) end)
    articles = backfill(Article, fn a -> text([a.title, a.summary, a.content]) end)

    Mix.shell().info("Done. Embedded #{notes} notes and #{articles} articles.")
  end

  defp backfill(schema, to_text) do
    from(r in schema, where: is_nil(r.embedding))
    |> Repo.all()
    |> Task.async_stream(
      fn row -> embed_row(row, to_text.(row)) end,
      max_concurrency: 4,
      timeout: :infinity
    )
    |> Enum.count(fn {:ok, result} -> result == :ok end)
  end

  defp embed_row(_row, ""), do: :skip

  defp embed_row(row, text) do
    case Embeddings.embed(text) do
      {:ok, vector} ->
        row |> Ecto.Changeset.change(embedding: vector) |> Repo.update!()
        :ok

      {:error, reason} ->
        Mix.shell().error("Skipped #{row.__struct__} #{row.id}: #{reason}")
        :skip
    end
  end

  defp text(parts) do
    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> String.trim()
  end
end
