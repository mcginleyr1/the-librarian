defmodule Librarian.Workers.DiscoverSourcesWorker do
  @moduledoc "Harvests new candidate sources and enqueues vetting for each."
  use Oban.Worker, queue: :stream, max_attempts: 3

  require Logger

  alias Librarian.Discovery
  alias Librarian.Workers.VetCandidateSourceWorker

  @impl Oban.Worker
  def perform(_job) do
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
