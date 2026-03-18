defmodule LibrarianWeb.ReaderLive do
  use LibrarianWeb, :live_view

  alias Librarian.Reader

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Librarian.PubSub, "reader:updates")
    end

    feeds_by_category = Reader.list_feeds_by_category()
    unread_counts = Reader.count_unread_by_feed()

    {:ok,
     socket
     |> assign(
       feeds_by_category: feeds_by_category,
       unread_counts: unread_counts,
       selected_feed_id: nil,
       selected_category: nil,
       selected_article: nil,
       filter: :unread,
       article_ids: [],
       current_index: -1,
       collapsed_categories: MapSet.new()
     )
     |> stream(:articles, [])}
  end

  @impl true
  def handle_params(%{"feed_id" => feed_id}, _uri, socket) do
    feed_id = String.to_integer(feed_id)
    articles = load_articles(feed_id, socket.assigns.filter)
    article_ids = Enum.map(articles, & &1.id)

    {:noreply,
     socket
     |> assign(
       selected_feed_id: feed_id,
       selected_category: nil,
       article_ids: article_ids,
       current_index: -1,
       selected_article: nil
     )
     |> stream(:articles, articles, reset: true)}
  end

  def handle_params(%{"category" => category_slug}, _uri, socket) do
    articles = load_articles_for_category(category_slug, socket.assigns.filter)
    article_ids = Enum.map(articles, & &1.id)

    {:noreply,
     socket
     |> assign(
       selected_feed_id: nil,
       selected_category: category_slug,
       article_ids: article_ids,
       current_index: -1,
       selected_article: nil
     )
     |> stream(:articles, articles, reset: true)}
  end

  def handle_params(_params, _uri, socket) do
    articles =
      case socket.assigns.filter do
        :starred -> Reader.list_starred_articles()
        _ -> Reader.list_all_unread_articles(limit: 50)
      end

    article_ids = Enum.map(articles, & &1.id)

    {:noreply,
     socket
     |> assign(
       selected_feed_id: nil,
       selected_category: nil,
       article_ids: article_ids,
       current_index: -1
     )
     |> stream(:articles, articles, reset: true)}
  end

  @impl true
  def handle_event("select_article", %{"id" => id}, socket) do
    article_id = String.to_integer(id)
    article = Reader.get_article!(article_id)
    Reader.mark_read(article_id)
    index = Enum.find_index(socket.assigns.article_ids, &(&1 == article_id)) || -1
    unread_counts = Map.update(socket.assigns.unread_counts, article.feed_id, 0, &max(0, &1 - 1))

    {:noreply,
     assign(socket, selected_article: article, current_index: index, unread_counts: unread_counts)}
  end

  def handle_event("toggle_star", %{"id" => id}, socket) do
    article_id = String.to_integer(id)
    article = Reader.get_article!(article_id)
    starred = !(article.read_state && article.read_state.starred)
    Reader.mark_starred(article_id, starred)

    updated_article =
      if socket.assigns.selected_article && socket.assigns.selected_article.id == article_id do
        put_in(socket.assigns.selected_article.read_state.starred, starred)
      else
        socket.assigns.selected_article
      end

    {:noreply, assign(socket, selected_article: updated_article)}
  end

  def handle_event("mark_all_read", _params, socket) do
    unread_counts =
      cond do
        socket.assigns.selected_feed_id ->
          Reader.mark_all_read_for_feed(socket.assigns.selected_feed_id)
          Map.put(socket.assigns.unread_counts, socket.assigns.selected_feed_id, 0)

        socket.assigns.selected_category ->
          actual_category =
            if socket.assigns.selected_category == "uncategorized",
              do: nil,
              else: socket.assigns.selected_category

          Reader.mark_all_read_for_category(actual_category)

          feed_ids =
            socket.assigns.feeds_by_category
            |> Map.get(actual_category, [])
            |> Enum.map(& &1.id)

          Enum.reduce(feed_ids, socket.assigns.unread_counts, &Map.put(&2, &1, 0))

        true ->
          Reader.mark_all_read()
          Map.new(socket.assigns.unread_counts, fn {k, _} -> {k, 0} end)
      end

    {:noreply,
     socket
     |> assign(unread_counts: unread_counts, article_ids: [], current_index: -1)
     |> stream(:articles, [], reset: true)}
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    filter = String.to_existing_atom(filter)
    socket = assign(socket, filter: filter)

    path =
      cond do
        socket.assigns.selected_feed_id -> "/reader/feed/#{socket.assigns.selected_feed_id}"
        socket.assigns.selected_category -> "/reader/category/#{socket.assigns.selected_category}"
        true -> "/reader"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("toggle_category", %{"category" => category_key}, socket) do
    collapsed = socket.assigns.collapsed_categories

    collapsed =
      if MapSet.member?(collapsed, category_key) do
        MapSet.delete(collapsed, category_key)
      else
        MapSet.put(collapsed, category_key)
      end

    {:noreply, assign(socket, collapsed_categories: collapsed)}
  end

  def handle_event("key_nav", %{"key" => key}, socket) do
    socket =
      case key do
        "j" -> navigate_to_index(socket, socket.assigns.current_index + 1)
        "k" -> navigate_to_index(socket, max(0, socket.assigns.current_index - 1))
        "r" -> socket
        "s" -> toggle_star_current(socket)
        "o" -> open_current_url(socket)
        _ -> socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:feed_updated, feed_id}, socket) do
    count = Reader.unread_count(feed_id)

    {:noreply,
     assign(socket, unread_counts: Map.put(socket.assigns.unread_counts, feed_id, count))}
  end

  defp load_articles(feed_id, :starred),
    do: Reader.list_starred_articles() |> Enum.filter(&(&1.feed_id == feed_id))

  defp load_articles(feed_id, :unread), do: Reader.list_articles(feed_id, unread_only: true)
  defp load_articles(feed_id, _), do: Reader.list_articles(feed_id)

  defp load_articles_for_category(category_slug, filter) do
    actual_category = if category_slug == "uncategorized", do: nil, else: category_slug

    case filter do
      :starred ->
        Reader.list_starred_articles()
        |> Enum.filter(fn a -> a.feed && a.feed.category == actual_category end)

      :unread ->
        Reader.list_articles_by_category(actual_category, unread_only: true)

      _ ->
        Reader.list_articles_by_category(actual_category)
    end
  end

  defp navigate_to_index(socket, index) do
    ids = socket.assigns.article_ids
    count = length(ids)

    if count == 0 do
      socket
    else
      index = min(index, count - 1) |> max(0)
      article_id = Enum.at(ids, index)
      article = Reader.get_article!(article_id)
      Reader.mark_read(article_id)

      unread_counts =
        Map.update(socket.assigns.unread_counts, article.feed_id, 0, &max(0, &1 - 1))

      assign(socket,
        selected_article: article,
        current_index: index,
        unread_counts: unread_counts
      )
    end
  end

  defp toggle_star_current(%{assigns: %{selected_article: nil}} = socket), do: socket

  defp toggle_star_current(socket) do
    article = socket.assigns.selected_article
    starred = !(article.read_state && article.read_state.starred)
    Reader.mark_starred(article.id, starred)

    read_state =
      (article.read_state || %Librarian.Reader.ReadState{}) |> Map.put(:starred, starred)

    assign(socket, selected_article: Map.put(article, :read_state, read_state))
  end

  defp open_current_url(%{assigns: %{selected_article: nil}} = socket), do: socket

  defp open_current_url(socket) do
    push_event(socket, "open_url", %{url: socket.assigns.selected_article.url})
  end
end
