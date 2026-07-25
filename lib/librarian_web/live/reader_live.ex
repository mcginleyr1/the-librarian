defmodule LibrarianWeb.ReaderLive do
  use LibrarianWeb, :live_view

  alias Librarian.Reader
  alias Librarian.Stream

  @page_size 50

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
       article_offset: 0,
       more_articles?: false,
       current_index: -1,
       pending_new: 0,
       collapsed_categories: MapSet.new(),
       show_feeds: false
     )
     |> stream(:articles, [])}
  end

  # Below `md` only one pane fits, so the three panes become a drill-down.
  defp mobile_pane(assigns) do
    cond do
      assigns.show_feeds -> :feeds
      assigns.selected_article -> :article
      true -> :list
    end
  end

  @impl true
  def handle_params(%{"feed_id" => feed_id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       selected_feed_id: String.to_integer(feed_id),
       selected_category: nil,
       current_index: -1,
       selected_article: nil,
       show_feeds: false
     )
     |> load_articles_page(reset: true)}
  end

  def handle_params(%{"category" => category_slug}, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       selected_feed_id: nil,
       selected_category: category_slug,
       current_index: -1,
       selected_article: nil,
       show_feeds: false
     )
     |> load_articles_page(reset: true)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       selected_feed_id: nil,
       selected_category: nil,
       current_index: -1,
       show_feeds: false
     )
     |> load_articles_page(reset: true)}
  end

  @impl true
  def handle_event("select_article", %{"id" => id}, socket) do
    article_id = String.to_integer(id)
    article = Reader.get_article!(article_id)
    Reader.mark_read(article_id)
    Stream.record_interaction(article_id, :open)
    index = Enum.find_index(socket.assigns.article_ids, &(&1 == article_id)) || -1
    unread_counts = Map.update(socket.assigns.unread_counts, article.feed_id, 0, &max(0, &1 - 1))

    {:noreply,
     assign(socket, selected_article: article, current_index: index, unread_counts: unread_counts)}
  end

  def handle_event("toggle_feeds", _params, socket) do
    {:noreply, assign(socket, show_feeds: !socket.assigns.show_feeds)}
  end

  def handle_event("back_to_list", _params, socket) do
    {:noreply, assign(socket, selected_article: nil)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.more_articles? do
      {:noreply, load_articles_page(socket, reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_star", %{"id" => id}, socket) do
    article_id = String.to_integer(id)
    article = Reader.get_article!(article_id)
    starred = !(article.read_state && article.read_state.starred)
    Reader.mark_starred(article_id, starred)
    if starred, do: Stream.record_interaction(article_id, :save)

    updated_article =
      if socket.assigns.selected_article && socket.assigns.selected_article.id == article_id do
        put_in(socket.assigns.selected_article.read_state.starred, starred)
      else
        socket.assigns.selected_article
      end

    {:noreply, assign(socket, selected_article: updated_article)}
  end

  def handle_event("feedback", %{"id" => id, "kind" => kind}, socket) do
    article_id = String.to_integer(id)
    Stream.record_interaction(article_id, kind)

    {:noreply, put_flash(socket, :info, "Got it — #{kind}d. Tuning your stream.")}
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
            |> Enum.find_value([], fn {cat, feeds} -> if cat == actual_category, do: feeds end)
            |> Enum.map(& &1.id)

          Enum.reduce(feed_ids, socket.assigns.unread_counts, &Map.put(&2, &1, 0))

        true ->
          Reader.mark_all_read()
          Map.new(socket.assigns.unread_counts, fn {k, _} -> {k, 0} end)
      end

    {:noreply,
     socket
     |> assign(
       unread_counts: unread_counts,
       article_ids: [],
       article_offset: 0,
       more_articles?: false,
       current_index: -1
     )
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

  def handle_event("show_new_articles", _params, socket) do
    {:noreply,
     socket
     |> assign(current_index: -1)
     |> load_articles_page(reset: true)}
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
  def handle_info({:feed_updated, feed_id, new_count}, socket) do
    socket =
      assign(socket,
        unread_counts:
          Map.put(socket.assigns.unread_counts, feed_id, Reader.unread_count(feed_id))
      )

    socket =
      if socket.assigns.filter != :starred and feed_in_scope?(socket.assigns, feed_id) do
        assign(socket, pending_new: socket.assigns.pending_new + new_count)
      else
        socket
      end

    {:noreply, socket}
  end

  defp feed_in_scope?(%{selected_feed_id: id}, feed_id) when not is_nil(id), do: id == feed_id

  defp feed_in_scope?(%{selected_category: slug} = assigns, feed_id) when not is_nil(slug) do
    category = if slug == "uncategorized", do: nil, else: slug

    assigns.feeds_by_category
    |> Enum.find_value([], fn {cat, feeds} -> if cat == category, do: feeds end)
    |> Enum.any?(&(&1.id == feed_id))
  end

  defp feed_in_scope?(_assigns, _feed_id), do: true

  defp load_articles_page(socket, opts) do
    reset = Keyword.fetch!(opts, :reset)
    offset = if reset, do: 0, else: socket.assigns.article_offset
    articles = fetch_articles(socket.assigns, offset)
    ids = Enum.map(articles, & &1.id)

    socket
    |> assign(
      article_ids: if(reset, do: ids, else: socket.assigns.article_ids ++ ids),
      article_offset: offset + length(articles),
      more_articles?: length(articles) == @page_size,
      pending_new: if(reset, do: 0, else: socket.assigns.pending_new)
    )
    |> stream(:articles, articles, reset: reset)
  end

  defp fetch_articles(%{selected_feed_id: feed_id, filter: filter}, offset)
       when not is_nil(feed_id),
       do: load_articles(feed_id, filter, offset)

  defp fetch_articles(%{selected_category: category, filter: filter}, offset)
       when not is_nil(category),
       do: load_articles_for_category(category, filter, offset)

  defp fetch_articles(%{filter: :starred}, _offset), do: Reader.list_starred_articles()

  defp fetch_articles(_assigns, offset),
    do: Reader.list_all_unread_articles(limit: @page_size, offset: offset)

  defp load_articles(feed_id, :starred, _offset),
    do: Reader.list_starred_articles() |> Enum.filter(&(&1.feed_id == feed_id))

  defp load_articles(feed_id, :unread, offset),
    do: Reader.list_articles(feed_id, unread_only: true, limit: @page_size, offset: offset)

  defp load_articles(feed_id, _filter, offset),
    do: Reader.list_articles(feed_id, limit: @page_size, offset: offset)

  defp load_articles_for_category(category_slug, filter, offset) do
    actual_category = if category_slug == "uncategorized", do: nil, else: category_slug

    case filter do
      :starred ->
        Reader.list_starred_articles()
        |> Enum.filter(fn a -> a.feed && a.feed.category == actual_category end)

      :unread ->
        Reader.list_articles_by_category(actual_category,
          unread_only: true,
          limit: @page_size,
          offset: offset
        )

      _ ->
        Reader.list_articles_by_category(actual_category, limit: @page_size, offset: offset)
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
