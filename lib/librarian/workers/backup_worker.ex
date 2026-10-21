defmodule Librarian.Workers.BackupWorker do
  @moduledoc """
  The cron entry (no args) enqueues one job per user; each user's job runs
  `Librarian.Backup.run/1` when their B2 settings are configured.
  """

  use Oban.Worker, queue: :backup, max_attempts: 3

  alias Librarian.{Accounts, Backup, Repo, Settings}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    Repo.with_user(user_id, fn ->
      settings = Settings.get_settings()
      if settings && Settings.configured?(), do: Backup.run(settings), else: :ok
    end)
  end

  def perform(_job), do: Accounts.enqueue_per_user(__MODULE__)
end
