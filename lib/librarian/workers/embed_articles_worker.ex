defmodule Librarian.Workers.EmbedArticlesWorker do
  @moduledoc """
  Embeds newly arrived articles and notes that don't have an embedding yet,
  so the personalized stream stays current. Runs on a short cron and after
  feed fetches. Retries (and logs) when the embedding serving fails, so rows
  whose embedding is still nil are picked up again by the next cron run.
  """
  use Oban.Worker, queue: :stream, max_attempts: 3

  import Ecto.Query
  require Logger

  alias Librarian.{Embeddings, Repo}
  alias Librarian.Reader.Article
  alias Librarian.Vault.Note

  @batch 200
  # The serving is compiled for batch_size: 16; embedding one item at a time
  # pays the full padded batch cost for every row.
  @embed_batch 16

  @impl Oban.Worker
  def perform(_job) do
    # Truncate wide, TOASTed columns (note body, article content) in SQL to the
    # embedding cap, so Postgres de-TOASTs only the ~8 KB prefix the model reads
    # instead of decompressing multi-MB bodies into one backend and OOMing it.
    max = Embeddings.max_chars()

    notes =
      from(n in Note,
        where: is_nil(n.embedding),
        limit: @batch,
        select: %{
          id: n.id,
          updated_at: n.updated_at,
          title: n.title,
          body: fragment("left(?, ?)", n.body, ^max)
        }
      )

    articles =
      from(a in Article,
        where: is_nil(a.embedding),
        limit: @batch,
        select: %{
          id: a.id,
          updated_at: a.updated_at,
          title: a.title,
          summary: fragment("left(?, ?)", a.summary, ^max),
          content: fragment("left(?, ?)", a.content, ^max)
        }
      )

    with {:ok, notes} <- embed_missing(notes, Note, fn r -> text([r.title, r.body]) end),
         {:ok, articles} <-
           embed_missing(articles, Article, fn r -> text([r.title, r.summary, r.content]) end) do
      Logger.info("EmbedArticlesWorker: embedded #{notes} notes, #{articles} articles")
      :ok
    end
  end

  # system pass over every user's rows: embedding is content processing
  defp embed_missing(query, schema, to_text) do
    query
    |> Repo.all(skip_tenant: true)
    |> Enum.chunk_every(@embed_batch)
    |> Enum.reduce_while(0, fn chunk, acc ->
      case Embeddings.embed_many(Enum.map(chunk, to_text)) do
        {:ok, vectors} ->
          store_embeddings(schema, chunk, vectors)
          {:cont, acc + length(chunk)}

        {:error, reason} ->
          Logger.warning("EmbedArticlesWorker: batch failed: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      count -> {:ok, count}
    end
  end

  # Matching updated_at skips a row edited since it was read: its text has
  # changed, so it keeps a nil embedding and the next run embeds the new text.
  defp store_embeddings(schema, chunk, vectors) do
    for {row, vector} <- Enum.zip(chunk, vectors) do
      Repo.update_all(
        from(r in schema, where: r.id == ^row.id and r.updated_at == ^row.updated_at),
        [set: [embedding: vector]],
        skip_tenant: true
      )
    end
  end

  defp text(parts) do
    parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n\n") |> String.trim()
  end
end
