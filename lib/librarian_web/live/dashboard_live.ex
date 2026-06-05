defmodule LibrarianWeb.DashboardLive do
  use LibrarianWeb, :live_view

  alias Librarian.{Discovery, Interest, Stream}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_event("rebuild", _params, socket) do
    Interest.rebuild()
    {:noreply, socket |> put_flash(:info, "Interest model rebuilt.") |> assign_data()}
  end

  defp assign_data(socket) do
    assign(socket,
      summary: Stream.signal_summary(),
      clusters: Interest.centroids(),
      topics: Enum.take(Interest.topic_frequencies(), 12),
      sources: Discovery.source_counts(),
      candidate_counts: Discovery.candidate_status_counts(),
      candidates: Enum.take(Discovery.list_candidates(), 10),
      profile_html: MDEx.to_html!(Interest.regenerate_profile_doc())
    )
  end
end
