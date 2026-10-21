defmodule Librarian.Workers.BuildGraphWorker do
  @moduledoc """
  Hourly graph maintenance: refreshes similarity edges from pgvector, then
  enqueues LLM edge typing for a bounded batch of embedded-but-unindexed
  notes. The batch cap paces API spend; the monthly budget in Settings is
  the hard stop.
  """
  use Oban.Worker, queue: :vault, max_attempts: 3

  import Ecto.Query
  require Logger

  alias Librarian.{LLM, Repo, Vault}
  alias Librarian.Vault.Note
  alias Librarian.Workers.ExtractEdgesWorker

  @batch 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}), do: Repo.with_user(user_id, &run/0)
  def perform(_job), do: Librarian.Accounts.enqueue_per_user(__MODULE__)

  defp run do
    {:ok, similarity_count} = Vault.generate_similarity_edges()

    enqueued =
      if LLM.configured?() and not LLM.budget_exceeded?() do
        from(n in Note,
          where: not is_nil(n.embedding) and is_nil(n.graph_indexed_at),
          order_by: [desc: n.inserted_at],
          limit: @batch,
          select: n.id
        )
        |> Repo.all()
        |> Enum.map(fn id -> %{"note_id" => id} |> ExtractEdgesWorker.new() |> Oban.insert() end)
        |> length()
      else
        0
      end

    Logger.info(
      "BuildGraphWorker: #{similarity_count} similarity edges, #{enqueued} notes enqueued for typing"
    )

    :ok
  end
end
