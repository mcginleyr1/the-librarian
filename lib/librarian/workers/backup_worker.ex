defmodule Librarian.Workers.BackupWorker do
  use Oban.Worker, queue: :backup, max_attempts: 3

  alias Librarian.{Settings, Backup}

  @impl Oban.Worker
  def perform(_job) do
    for user_id <- Librarian.Accounts.list_user_ids() do
      Librarian.Repo.with_user(user_id, fn ->
        case Settings.get_settings() do
          nil -> :ok
          settings -> if Settings.configured?(), do: Backup.run(settings), else: :ok
        end
      end)
    end

    :ok
  end
end
