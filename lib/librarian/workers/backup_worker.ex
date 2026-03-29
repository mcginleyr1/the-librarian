defmodule Librarian.Workers.BackupWorker do
  use Oban.Worker, queue: :backup, max_attempts: 3

  alias Librarian.{Settings, Backup}

  @impl Oban.Worker
  def perform(_job) do
    case Settings.get_settings() do
      nil ->
        :ok

      settings ->
        if Settings.configured?() do
          Backup.run(settings)
        else
          :ok
        end
    end
  end
end
