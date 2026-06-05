defmodule Librarian.Workers.EmbedArticlesWorker do
  @moduledoc """
  Embeds newly arrived articles and notes that don't have an embedding yet,
  so the personalized stream stays current. Runs on a short cron and after
  feed fetches. No-op (and retries) if the embedding serving isn't running.
  """
  use Oban.Worker, queue: :stream, max_attempts: 3

  import Ecto.Query
  require Logger

  alias Librarian.{Embeddings, Repo}
  alias Librarian.Reader.Article
  alias Librarian.Vault.Note

  @batch 200

  @impl Oban.Worker
  def perform(_job) do
    notes = embed_missing(Note, fn n -> text([n.title, n.body]) end)
    articles = embed_missing(Article, fn a -> text([a.title, a.summary, a.content]) end)
    Logger.info("EmbedArticlesWorker: embedded #{notes} notes, #{articles} articles")
    :ok
  end

  defp embed_missing(schema, to_text) do
    from(r in schema, where: is_nil(r.embedding), limit: @batch)
    |> Repo.all()
    |> Enum.reduce(0, fn row, acc ->
      case Embeddings.embed(to_text.(row)) do
        {:ok, vector} ->
          row |> Ecto.Changeset.change(embedding: vector) |> Repo.update!()
          acc + 1

        {:error, _reason} ->
          acc
      end
    end)
  end

  defp text(parts) do
    parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n") |> String.trim()
  end
end
