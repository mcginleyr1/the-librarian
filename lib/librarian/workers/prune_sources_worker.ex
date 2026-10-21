defmodule Librarian.Workers.PruneSourcesWorker do
  @moduledoc "Deactivates discovered feeds the user doesn't engage with."
  use Oban.Worker, queue: :stream, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Librarian.Repo.with_user(user_id, fn ->
      count = Librarian.Discovery.prune_sources()
      Logger.info("PruneSourcesWorker: pruned #{count} discovered feeds")
    end)
  end

  def perform(_job), do: Librarian.Accounts.enqueue_per_user(__MODULE__)
end
