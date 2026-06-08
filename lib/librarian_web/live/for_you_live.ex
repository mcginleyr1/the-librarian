defmodule LibrarianWeb.ForYouLive do
  use LibrarianWeb, :live_view

  alias Librarian.{Interest, LinkPreview, Ranking, Reader, Stream}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       summary: Stream.signal_summary(),
       centroid_count: length(Interest.centroids()),
       topics: Ranking.available_topics(),
       active_topic: nil
     )
     |> load_stream()}
  end

  @impl true
  def handle_event("feedback", %{"id" => id, "kind" => kind}, socket) do
    Stream.record_interaction(String.to_integer(id), kind)

    {:noreply,
     socket
     |> assign(summary: Stream.signal_summary())
     |> put_flash(
       :info,
       "Got it — re-ranking. Rebuild the model from the Dashboard to fold this in."
     )
     |> load_stream()}
  end

  def handle_event("open", %{"id" => id}, socket) do
    article_id = String.to_integer(id)
    Reader.mark_read(article_id)
    Stream.record_interaction(article_id, :open)
    {:noreply, socket}
  end

  def handle_event("filter_topic", %{"topic" => topic}, socket) do
    active = if socket.assigns.active_topic == topic, do: nil, else: topic
    {:noreply, socket |> assign(active_topic: active) |> load_stream()}
  end

  defp load_stream(socket) do
    entries =
      Ranking.rank_stream(limit: 30, topic: socket.assigns.active_topic)
      |> Enum.map(fn entry ->
        entry
        |> Map.put(:id, entry.article.id)
        |> Map.put(:preview, LinkPreview.for_article(entry.article))
      end)

    socket
    |> assign(count: length(entries), empty?: entries == [])
    |> stream(:entries, entries, reset: true, dom_id: &"entry-#{&1.id}")
  end
end
