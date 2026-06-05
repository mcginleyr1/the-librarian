defmodule Librarian.Workers.TagArticlesWorker do
  @moduledoc "Tags newly fetched articles with structured topics/content-type."
  use Oban.Worker, queue: :stream, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    count = Librarian.Tagging.tag_untagged()
    Logger.info("TagArticlesWorker: tagged #{count} articles")
    :ok
  end
end
