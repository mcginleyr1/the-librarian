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

  @doc "Schedules a debounced rebuild; a burst of one user's signals collapses into one job."
  def enqueue do
    %{"user_id" => Librarian.Repo.user_id!()}
    |> new(schedule_in: @debounce, unique: [period: @debounce, states: [:available, :scheduled]])
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Librarian.Repo.with_user(user_id, fn ->
      {:ok, k} = Librarian.Interest.rebuild()
      Logger.info("RebuildInterestWorker: rebuilt #{k} interest centroids")
      :ok
    end)
  end
end
