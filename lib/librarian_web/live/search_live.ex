defmodule LibrarianWeb.SearchLive do
  use LibrarianWeb, :live_view
  import Ecto.Query
  alias Librarian.{Repo, Vault}
  alias Librarian.Reader.{Article, Feed}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, query: "", results: [], filter: :all)}
  end

  @impl true
  def handle_params(%{"q" => q}, _uri, socket) do
    results = do_search(q, socket.assigns.filter)
    {:noreply, assign(socket, query: q, results: results)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    results = do_search(q, socket.assigns.filter)
    {:noreply, assign(socket, query: q, results: results)}
  end

  def handle_event("set_filter", %{"filter" => f}, socket) do
    filter = String.to_existing_atom(f)
    results = do_search(socket.assigns.query, filter)
    {:noreply, assign(socket, filter: filter, results: results)}
  end

  defp do_search("", _), do: []

  defp do_search(q, filter) do
    articles = if filter in [:all, :articles], do: search_articles(q), else: []
    notes = if filter in [:all, :notes], do: search_notes(q), else: []
    articles ++ notes
  end

  defp search_articles(q) do
    Repo.all(
      from a in Article,
        join: f in Feed,
        on: f.id == a.feed_id,
        where: fragment("a0.search_vector @@ plainto_tsquery('english', ?)", ^q),
        order_by: [desc: fragment("ts_rank(a0.search_vector, plainto_tsquery('english', ?))", ^q)],
        limit: 20,
        select: %{
          type: "article",
          id: a.id,
          title: a.title,
          subtitle: f.title,
          url: a.url,
          preview: fragment("left(coalesce(?, ''), 200)", a.summary),
          date: a.published_at
        }
    )
  end

  defp search_notes(q) do
    Vault.search(q)
    |> Enum.map(fn n ->
      %{
        type: "note",
        id: n.id,
        title: n.title || "(Untitled)",
        subtitle: n.notebook && n.notebook.name,
        url: nil,
        preview: String.slice(n.body || "", 0, 200),
        date: n.inserted_at
      }
    end)
  end
end
