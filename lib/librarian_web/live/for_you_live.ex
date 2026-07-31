defmodule LibrarianWeb.ForYouLive do
  use LibrarianWeb, :live_view

  alias Librarian.{Interest, LinkPreview, Ranking, Reader, Settings, Stream}

  @impl true
  def mount(_params, _session, socket) do
    categories = Reader.list_categories()

    {:ok,
     socket
     |> assign(
       summary: Stream.signal_summary(),
       centroid_count: length(Interest.centroids()),
       topics: Ranking.available_topics(),
       lenses: Enum.filter(Settings.pinned_lenses(), &(&1 in categories)),
       active_topic: nil,
       active_category: nil
     )
     |> load_stream()}
  end

  @impl true
  # Terminal feedback removes just that card — no re-rank, so the rest of the
  # list stays put. Fresh ranking happens on the next mount or filter change.
  def handle_event("feedback", %{"id" => id, "kind" => kind}, socket) do
    article_id = String.to_integer(id)
    Stream.record_interaction(article_id, kind)
    if kind in ~w(like dislike done), do: Reader.mark_read(article_id)
    count = max(socket.assigns.count - 1, 0)

    {:noreply,
     socket
     |> assign(summary: Stream.signal_summary(), count: count, empty?: count == 0)
     |> stream_delete_by_dom_id(:entries, "entry-#{article_id}")}
  end

  def handle_event("open", %{"id" => id}, socket) do
    article_id = String.to_integer(id)
    Reader.mark_read(article_id)
    Stream.record_interaction(article_id, :open)
    {:noreply, socket}
  end

  def handle_event("filter_topic", %{"topic" => topic}, socket) do
    active = if socket.assigns.active_topic == topic, do: nil, else: topic
    {:noreply, socket |> assign(active_topic: active, active_category: nil) |> load_stream()}
  end

  def handle_event("filter_category", %{"category" => category}, socket) do
    active = if socket.assigns.active_category == category, do: nil, else: category
    {:noreply, socket |> assign(active_category: active, active_topic: nil) |> load_stream()}
  end

  defp load_stream(socket) do
    entries =
      Ranking.rank_stream(
        limit: 30,
        topic: socket.assigns.active_topic,
        category: socket.assigns.active_category
      )
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
