defmodule Librarian.Workers.RebuildInterestWorker do
  @moduledoc """
  Recomputes the interest centroids from the current positive corpus. Enqueued
  (debounced) whenever model-affecting signal arrives — a like/save/read/done
  interaction or a new vault note. Oban job uniqueness collapses a burst of
  signals into a single rebuild that fires ~30 min later, so the model stays
  fresh without rebuilding on every click.
  """
  use Oban.Worker, queue: :stream, max_attempts: 3

  require Logger

  @debounce 1800

  @doc "Schedules a debounced rebuild; a burst of signals collapses into one job."
  def enqueue do
    %{}
    |> new(schedule_in: @debounce, unique: [period: @debounce, states: [:available, :scheduled]])
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(_job) do
    {:ok, k} = Librarian.Interest.rebuild()
    Logger.info("RebuildInterestWorker: rebuilt #{k} interest centroids")
    :ok
  end
end
