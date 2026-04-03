defmodule Librarian.Workers.CurateFeedsWorker do
  @moduledoc """
  Triggers the Claude Code feed curation agent on the host machine.

  Runs 1 hour after ScheduleFeedsWorker (which runs every 2 hours).
  Sends a POST to the curate-server running on the Mac mini host.
  """

  use Oban.Worker, queue: :feeds, max_attempts: 1

  require Logger

  @curate_url "http://host.internal:9723/curate"

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("CurateFeedsWorker: triggering curation agent")

    case Req.post(@curate_url, receive_timeout: 5_000) do
      {:ok, %{status: 202, body: body}} ->
        Logger.info("CurateFeedsWorker: curation started — #{inspect(body)}")
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("CurateFeedsWorker: unexpected status #{status}")
        :ok

      {:error, reason} ->
        Logger.error("CurateFeedsWorker: failed to reach curate server — #{inspect(reason)}")
        {:error, reason}
    end
  end
end
