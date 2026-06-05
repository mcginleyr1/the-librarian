defmodule LibrarianWeb.ForYouLive do
  use LibrarianWeb, :live_view

  alias Librarian.{Interest, Ranking, Stream}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(summary: Stream.signal_summary(), centroid_count: length(Interest.centroids()))
     |> load_stream()}
  end

  @impl true
  def handle_event("feedback", %{"id" => id, "kind" => kind}, socket) do
    Stream.record_interaction(String.to_integer(id), kind)
    Interest.rebuild()

    {:noreply,
     socket
     |> assign(summary: Stream.signal_summary(), centroid_count: length(Interest.centroids()))
     |> put_flash(:info, "Tuned your stream — re-ranking.")
     |> load_stream()}
  end

  defp load_stream(socket) do
    entries =
      Ranking.rank_stream(limit: 30)
      |> Enum.map(&Map.put(&1, :id, &1.article.id))

    socket
    |> assign(count: length(entries), empty?: entries == [])
    |> stream(:entries, entries, reset: true, dom_id: &"entry-#{&1.id}")
  end
end
