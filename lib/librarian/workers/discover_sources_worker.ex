defmodule Librarian.Workers.DiscoverSourcesWorker do
  @moduledoc "Harvests new candidate sources and enqueues vetting for each."
  use Oban.Worker, queue: :stream, max_attempts: 3

  require Logger

  alias Librarian.Discovery
  alias Librarian.Workers.VetCandidateSourceWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Librarian.Repo.with_user(user_id, fn ->
      if Librarian.Settings.discovery_paused?(), do: :ok, else: run()
    end)
  end

  def perform(_job), do: Librarian.Accounts.enqueue_per_user(__MODULE__)

  defp run do
    link_graph = Discovery.harvest_link_graph()
    aggregator = Discovery.harvest_aggregators()

    Logger.info(
      "DiscoverSourcesWorker: #{length(link_graph)} link-graph + #{length(aggregator)} aggregator candidates"
    )

    Discovery.list_candidates("pending")
    |> Enum.each(fn c -> %{"id" => c.id} |> VetCandidateSourceWorker.new() |> Oban.insert() end)

    :ok
  end
end
