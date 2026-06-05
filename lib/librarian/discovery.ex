defmodule Librarian.Discovery do
  @moduledoc """
  The self-managing source pool (P4). The system grows and prunes feeds so the
  user never adds or removes a site.

  - `harvest_link_graph/0` mines outbound links from articles the user liked/saved;
    recurring new domains become `CandidateSource`s.
  - `vet_candidate/1` runs the existing `FeedDiscoverer` on a candidate domain and,
    if a feed is found, subscribes it as a low-trust `discovered` feed on probation.
  - `recompute_like_rates/0` + `prune_sources/0` retire discovered feeds the user
    doesn't engage with.
  """

  import Ecto.Query

  alias Librarian.Repo
  alias Librarian.Stream
  alias Librarian.Reader
  alias Librarian.Reader.{Article, Feed}
  alias Librarian.Reader.FeedDiscoverer
  alias Librarian.Discovery.CandidateSource
  alias Librarian.Stream.Interaction

  @prune_threshold 0.05
  @prune_min_opens 8
  @aggregator_hosts ~w(news.ycombinator.com lobste.rs reddit.com slashdot.org)

  @doc "Mines liked/saved articles for new outbound domains (link-graph channel)."
  def harvest_link_graph do
    Stream.positive_article_ids()
    |> articles_with_content()
    |> harvest_domains("link_graph")
  end

  @doc """
  Mines aggregator feeds (HN/Lobsters/Reddit/Slashdot) for new outbound domains,
  independent of what the user has reacted to (aggregator channel).
  """
  def harvest_aggregators(opts \\ []) do
    limit = Keyword.get(opts, :per_feed, 50)

    aggregator_articles(limit)
    |> harvest_domains("aggregator")
  end

  defp harvest_domains(articles, channel) do
    existing = existing_domains()

    articles
    |> Enum.flat_map(fn a -> Enum.map(extract_domains(a.content), &{&1, a.id}) end)
    |> Enum.reject(fn {domain, _id} -> is_nil(domain) or MapSet.member?(existing, domain) end)
    |> Enum.group_by(fn {domain, _id} -> domain end)
    |> Enum.map(fn {domain, hits} ->
      upsert_candidate(domain, channel, elem(hd(hits), 1), length(hits))
    end)
  end

  defp aggregator_articles(limit) do
    feed_ids =
      Repo.all(
        from f in Feed,
          where:
            f.category == "aggregators" or
              fragment("split_part(?, '/', 3)", f.feed_url) in ^@aggregator_hosts,
          select: f.id
      )

    Repo.all(
      from a in Article,
        where: a.feed_id in ^feed_ids and not is_nil(a.content),
        order_by: [desc: a.published_at],
        limit: ^limit,
        select: %{id: a.id, content: a.content}
    )
  end

  def list_candidates(status \\ nil) do
    query = from c in CandidateSource, order_by: [desc: c.mention_count]
    query = if status, do: from(c in query, where: c.status == ^status), else: query
    Repo.all(query)
  end

  @doc "Candidate counts grouped by status, e.g. %{\"pending\" => 4, \"accepted\" => 1}."
  def candidate_status_counts do
    Repo.all(from c in CandidateSource, group_by: c.status, select: {c.status, count(c.id)})
    |> Map.new()
  end

  @doc "Feed pool health: counts of manual vs discovered (and active discovered) feeds."
  def source_counts do
    rows =
      Repo.all(
        from f in Feed,
          group_by: [f.origin, f.active],
          select: {f.origin, f.active, count(f.id)}
      )

    %{
      manual: sum_where(rows, fn {o, _a, _n} -> o == "manual" end),
      discovered: sum_where(rows, fn {o, _a, _n} -> o == "discovered" end),
      discovered_active: sum_where(rows, fn {o, a, _n} -> o == "discovered" and a end)
    }
  end

  defp sum_where(rows, pred) do
    rows |> Enum.filter(pred) |> Enum.reduce(0, fn {_o, _a, n}, acc -> acc + n end)
  end

  @doc """
  Vets a candidate: discover its feed and, if found, subscribe it as a discovered
  feed on probation. Returns `{:ok, :accepted | :rejected}`.
  """
  def vet_candidate(%CandidateSource{} = candidate) do
    case FeedDiscoverer.discover(candidate.domain) do
      {:ok, [%{url: feed_url} = feed | _]} ->
        subscribe_discovered(feed_url, feed[:title] || candidate.domain)
        mark(candidate, %{status: "accepted", feed_url: feed_url})
        {:ok, :accepted}

      _ ->
        mark(candidate, %{status: "rejected"})
        {:ok, :rejected}
    end
  end

  @doc "Recomputes each feed's like_rate from interactions on its articles."
  def recompute_like_rates do
    for feed <- Repo.all(Feed) do
      stats = feed_signal_stats(feed.id)
      total = stats.positive + stats.negative + stats.opens

      rate = if total > 0, do: (stats.positive - stats.negative) / total, else: nil
      feed |> Ecto.Changeset.change(like_rate: rate) |> Repo.update!()
    end
  end

  @doc "Deactivates discovered feeds the user has seen enough of but doesn't like."
  def prune_sources do
    recompute_like_rates()

    {count, _} =
      Repo.update_all(
        from(f in Feed,
          where:
            f.origin == "discovered" and f.active == true and
              not is_nil(f.like_rate) and f.like_rate < @prune_threshold and
              fragment(
                "(SELECT count(*) FROM interactions i JOIN articles a ON a.id = i.article_id WHERE a.feed_id = ? AND i.kind = 'open') >= ?",
                f.id,
                @prune_min_opens
              )
        ),
        set: [active: false]
      )

    count
  end

  # --- helpers ---

  defp subscribe_discovered(feed_url, title) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Reader.upsert_feed(%{title: title, feed_url: feed_url}) do
      {:ok, feed} ->
        feed
        |> Ecto.Changeset.change(origin: "discovered", trust_score: 0.3, discovered_at: now)
        |> Repo.update()

      other ->
        other
    end
  end

  defp upsert_candidate(domain, channel, article_id, mentions) do
    %CandidateSource{}
    |> CandidateSource.changeset(%{
      domain: domain,
      channel: channel,
      discovered_from_article_id: article_id,
      mention_count: mentions
    })
    |> Repo.insert(
      on_conflict: [set: [mention_count: mentions]],
      conflict_target: :domain
    )
  end

  defp mark(candidate, attrs) do
    candidate |> CandidateSource.changeset(attrs) |> Repo.update!()
  end

  defp articles_with_content(ids) do
    Repo.all(
      from a in Article,
        where: a.id in ^ids and not is_nil(a.content),
        select: %{id: a.id, content: a.content}
    )
  end

  defp existing_domains do
    Repo.all(from f in Feed, select: {f.site_url, f.feed_url})
    |> Enum.flat_map(fn {site, feed} -> [domain(site), domain(feed)] end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @doc false
  def extract_domains(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.attribute("a", "href")
        |> Enum.map(&domain/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  def extract_domains(_), do: []

  defp domain(nil), do: nil

  defp domain(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host |> String.downcase() |> String.replace_prefix("www.", "")

      _ ->
        nil
    end
  end

  defp feed_signal_stats(feed_id) do
    rows =
      Repo.all(
        from i in Interaction,
          join: a in Article,
          on: a.id == i.article_id,
          where: a.feed_id == ^feed_id,
          group_by: i.kind,
          select: {i.kind, count(i.id)}
      )
      |> Map.new()

    %{
      positive: sum_kinds(rows, Stream.positive_kinds()),
      negative: sum_kinds(rows, Stream.negative_kinds()),
      opens: Map.get(rows, "open", 0)
    }
  end

  defp sum_kinds(rows, kinds), do: Enum.reduce(kinds, 0, &(&2 + Map.get(rows, &1, 0)))
end
