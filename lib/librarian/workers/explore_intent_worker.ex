defmodule Librarian.Workers.ExploreIntentWorker do
  @moduledoc "Intent channel: LLM-suggests sources for a user-named area, then enqueues vetting."
  use Oban.Worker, queue: :stream, max_attempts: 2

  require Logger

  alias Librarian.Discovery
  alias Librarian.Workers.VetCandidateSourceWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"query" => query}}) do
    case Discovery.explore(query) do
      {:ok, candidates} ->
        Logger.info("ExploreIntentWorker: #{length(candidates)} candidates for #{inspect(query)}")

        Enum.each(candidates, fn c ->
          %{"id" => c.id} |> VetCandidateSourceWorker.new() |> Oban.insert()
        end)

        :ok

      {:error, reason} when reason in [:no_api_key, :budget_exceeded] ->
        Logger.warning("ExploreIntentWorker: skipped (#{reason})")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
