defmodule Librarian.Workers.VetCandidateSourceWorker do
  @moduledoc "Vets one candidate source: discover its feed and subscribe if good."
  use Oban.Worker, queue: :stream, max_attempts: 2

  require Logger

  alias Librarian.Discovery
  alias Librarian.Discovery.CandidateSource
  alias Librarian.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case Repo.get(CandidateSource, id, skip_tenant: true) do
      nil ->
        :ok

      candidate ->
        Repo.with_user(candidate.user_id, fn ->
          {:ok, outcome} = Discovery.vet_candidate(candidate)
          Logger.info("VetCandidateSourceWorker: #{candidate.domain} -> #{outcome}")
          :ok
        end)
    end
  end
end
