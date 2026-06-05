defmodule Librarian.Workers.DiscoverSourcesWorker do
  @moduledoc "Harvests new candidate sources and enqueues vetting for each."
  use Oban.Worker, queue: :stream, max_attempts: 3

  require Logger

  alias Librarian.Discovery
  alias Librarian.Workers.VetCandidateSourceWorker

  @impl Oban.Worker
  def perform(_job) do
    candidates = Discovery.harvest_link_graph()
    Logger.info("DiscoverSourcesWorker: #{length(candidates)} candidate domains")

    Discovery.list_candidates("pending")
    |> Enum.each(fn c -> %{"id" => c.id} |> VetCandidateSourceWorker.new() |> Oban.insert() end)

    :ok
  end
end
