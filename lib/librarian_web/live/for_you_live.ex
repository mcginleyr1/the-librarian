defmodule LibrarianWeb.ForYouLive do
  use LibrarianWeb, :live_view

  alias Librarian.{Discovery, Interest, LinkPreview, LLM, Ranking, Reader, Settings, Stream}
  alias Librarian.Workers.ExploreIntentWorker

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
       active_category: nil,
       show_discover: false,
       discover_candidates: [],
       discovery_paused: false,
       llm_ready: false
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

  def handle_event("toggle_discover", _params, socket) do
    if socket.assigns.show_discover do
      {:noreply, assign(socket, show_discover: false)}
    else
      {:noreply, socket |> assign(show_discover: true) |> load_discover()}
    end
  end

  def handle_event("explore_intent", %{"query" => query}, socket) do
    case String.trim(query) do
      "" ->
        {:noreply, socket}

      query ->
        %{"query" => query} |> ExploreIntentWorker.new() |> Oban.insert()

        {:noreply,
         socket
         |> put_flash(:info, "Exploring “#{query}” — sources will appear on probation shortly.")
         |> load_discover()}
    end
  end

  def handle_event("dismiss_candidate", %{"id" => id}, socket) do
    Discovery.dismiss_candidate(String.to_integer(id))
    {:noreply, load_discover(socket)}
  end

  def handle_event("toggle_discovery_paused", _params, socket) do
    {:ok, _} = Settings.save_settings(%{discovery_paused: !socket.assigns.discovery_paused})
    {:noreply, load_discover(socket)}
  end

  def handle_event("filter_topic", %{"topic" => topic}, socket) do
    active = if socket.assigns.active_topic == topic, do: nil, else: topic
    {:noreply, socket |> assign(active_topic: active, active_category: nil) |> load_stream()}
  end

  def handle_event("filter_category", %{"category" => category}, socket) do
    active = if socket.assigns.active_category == category, do: nil, else: category
    {:noreply, socket |> assign(active_category: active, active_topic: nil) |> load_stream()}
  end

  defp candidate_status_class("accepted"), do: "bg-success/10 text-success"
  defp candidate_status_class("rejected"), do: "bg-base-300 text-base-content/50"
  defp candidate_status_class(_pending_or_vetting), do: "bg-warning/10 text-warning"

  defp load_discover(socket) do
    assign(socket,
      discover_candidates: Discovery.recent_candidates(),
      discovery_paused: Settings.discovery_paused?(),
      llm_ready: LLM.configured?()
    )
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
