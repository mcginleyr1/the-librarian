defmodule Librarian.Workers.PruneSourcesWorker do
  @moduledoc "Deactivates discovered feeds the user doesn't engage with."
  use Oban.Worker, queue: :stream, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    Librarian.Accounts.each_user(fn ->
      count = Librarian.Discovery.prune_sources()
      Logger.info("PruneSourcesWorker: pruned #{count} discovered feeds")
    end)
  end
end
