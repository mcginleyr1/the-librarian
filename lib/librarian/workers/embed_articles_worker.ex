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
    # Truncate wide, TOASTed columns (note body, article content) in SQL to the
    # embedding cap, so Postgres de-TOASTs only the ~8 KB prefix the model reads
    # instead of decompressing multi-MB bodies into one backend and OOMing it.
    max = Embeddings.max_chars()

    notes =
      from(n in Note,
        where: is_nil(n.embedding),
        limit: @batch,
        select: %{id: n.id, title: n.title, body: fragment("left(?, ?)", n.body, ^max)}
      )
      |> embed_missing(Note, fn r -> text([r.title, r.body]) end)

    articles =
      from(a in Article,
        where: is_nil(a.embedding),
        limit: @batch,
        select: %{
          id: a.id,
          title: a.title,
          summary: fragment("left(?, ?)", a.summary, ^max),
          content: fragment("left(?, ?)", a.content, ^max)
        }
      )
      |> embed_missing(Article, fn r -> text([r.title, r.summary, r.content]) end)

    Logger.info("EmbedArticlesWorker: embedded #{notes} notes, #{articles} articles")
    :ok
  end

  # system pass over every user's rows: embedding is content processing
  defp embed_missing(query, schema, to_text) do
    query
    |> Repo.all(skip_tenant: true)
    |> Enum.reduce(0, fn row, acc ->
      case Embeddings.embed(to_text.(row)) do
        {:ok, vector} ->
          Repo.update_all(
            from(r in schema, where: r.id == ^row.id),
            [set: [embedding: vector]],
            skip_tenant: true
          )

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
