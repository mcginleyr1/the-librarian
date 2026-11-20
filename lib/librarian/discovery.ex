defmodule Librarian.Discovery do
  @moduledoc """
  The self-managing source pool (P4). The system grows and prunes feeds so the
  user never adds or removes a site.

  - `harvest_link_graph/0` mines outbound links from articles the user liked/saved;
    recurring new domains become `CandidateSource`s.
  - `explore/1` is the intent channel: the user names an area they want to
    discover, the LLM proposes sources for it, and they enter the same pipeline.
  - `vet_candidate/1` runs the existing `FeedDiscoverer` on a candidate (the site
    as it was supplied, then its bare domain) and, if a feed is found, subscribes
    it as a low-trust `discovered` feed on probation.
  - `recompute_like_rates/0` + `prune_sources/0` retire discovered feeds the user
    doesn't engage with.
  """

  import Ecto.Query

  alias Librarian.LLM
  alias Librarian.Repo
  alias Librarian.Stream
  alias Librarian.Reader
  alias Librarian.Reader.{Article, Feed, Subscription}
  alias Librarian.Reader.FeedDiscoverer
  alias Librarian.Discovery.CandidateSource
  alias Librarian.Stream.Interaction
  alias Librarian.Workers.VetCandidateSourceWorker

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

  @doc """
  Intent channel: asks the LLM for strong sources covering `query` and registers
  them as candidates for the usual vet -> probation -> prune pipeline. Accepted
  feeds get `query` as their Reader category so the new area stays findable.
  Returns `{:ok, candidates}` or `{:error, :no_api_key | :budget_exceeded | term}`.
  """
  def explore(query) do
    query = String.trim(query)

    with {:ok, %{"sources" => sources}} <-
           LLM.complete(explore_prompt(query), explore_schema(), purpose: "explore") do
      {:ok, register_intent_sources(sources, query)}
    end
  end

  @doc """
  Follows sites the user picked (in a chat with an assistant, say): each
  becomes an intent candidate in `category` and is vetted in the background
  like any other, its feed found and subscribed on probation. Returns
  `{queued, skipped}`: the candidates queued, and the sites passed over
  because the user already follows them or they aren't a domain or URL.
  """
  def follow_sites(sites, category) do
    queued = register_intent_sources(Enum.map(sites, &%{"domain" => &1}), category)
    Enum.each(queued, &(%{"id" => &1.id} |> VetCandidateSourceWorker.new() |> Oban.insert!()))

    queued_domains = MapSet.new(queued, & &1.domain)
    {queued, Enum.reject(sites, &(normalize_domain(&1) in queued_domains))}
  end

  @doc false
  def register_intent_sources(sources, query) do
    existing = existing_domains()

    sources
    |> Enum.map(&{normalize_domain(&1["domain"]), &1["domain"]})
    |> Enum.reject(fn {dom, _site} -> is_nil(dom) or MapSet.member?(existing, dom) end)
    |> Enum.uniq_by(fn {dom, _site} -> dom end)
    |> Enum.map(fn {dom, site} ->
      site_url = String.trim(site)

      {:ok, candidate} =
        %CandidateSource{user_id: Repo.user_id!()}
        |> CandidateSource.changeset(%{
          domain: dom,
          site_url: site_url,
          channel: "intent",
          intent_query: query
        })
        |> Repo.insert(
          on_conflict: [set: [intent_query: query, site_url: site_url]],
          conflict_target: [:user_id, :domain]
        )

      candidate
    end)
  end

  defp explore_prompt(query) do
    """
    I use an RSS reader and want to start exploring a new area: "#{query}".

    Suggest up to 10 established, currently active websites that publish
    high-quality writing on this topic — blogs, magazines, newsletters,
    institutional or practitioner sites — and are likely to offer an RSS or
    Atom feed. Prefer independent voices and primary sources over aggregators,
    social media, or link roundups. Return the bare domain for each.
    """
  end

  defp explore_schema do
    %{
      type: "object",
      properties: %{
        sources: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              domain: %{type: "string", description: "bare domain, e.g. example.com"},
              title: %{type: "string"}
            },
            required: ["domain", "title"],
            additionalProperties: false
          }
        }
      },
      required: ["sources"],
      additionalProperties: false
    }
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
        from s in Subscription,
          join: f in Feed,
          on: f.id == s.feed_id,
          where:
            s.category == "aggregators" or
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

  @doc "Recent candidates, newest activity first (for the Discover popup)."
  def recent_candidates(limit \\ 20) do
    Repo.all(from c in CandidateSource, order_by: [desc: c.updated_at], limit: ^limit)
  end

  @doc "Removes a candidate; a pending one is cleanly cancelled (its vet job no-ops)."
  def dismiss_candidate(id) do
    if candidate = Repo.get(CandidateSource, id), do: Repo.delete(candidate)
    :ok
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
        from s in Subscription,
          group_by: [s.origin, s.active],
          select: {s.origin, s.active, count(s.id)}
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
    with {:ok, [%{url: feed_url} = feed | _]} <- discover_feeds(candidate),
         {:ok, _feed} <-
           subscribe_discovered(
             feed_url,
             feed[:title] || candidate.domain,
             candidate.intent_query
           ) do
      mark(candidate, %{status: "accepted", feed_url: feed_url})
      {:ok, :accepted}
    else
      _ ->
        mark(candidate, %{status: "rejected"})
        {:ok, :rejected}
    end
  end

  @doc "Recomputes each subscription's like_rate from interactions on its feed's articles."
  def recompute_like_rates do
    stats = signal_stats_by_user_feed()

    for sub <- Repo.all(Subscription) do
      rows = Map.get(stats, {sub.user_id, sub.feed_id}, %{})
      positive = sum_kinds(rows, Stream.positive_kinds())
      negative = sum_kinds(rows, Stream.negative_kinds())
      opens = Map.get(rows, "open", 0)
      total = positive + negative + opens

      rate = if total > 0, do: (positive - negative) / total, else: nil
      sub |> Ecto.Changeset.change(like_rate: rate) |> Repo.update!()
    end
  end

  # One grouped read for every subscription instead of a query per subscription.
  defp signal_stats_by_user_feed do
    Repo.all(
      from i in Interaction,
        join: a in Article,
        on: a.id == i.article_id,
        group_by: [i.user_id, a.feed_id, i.kind],
        select: {i.user_id, a.feed_id, i.kind, count(i.id)}
    )
    |> Enum.reduce(%{}, fn {user_id, feed_id, kind, count}, acc ->
      Map.update(acc, {user_id, feed_id}, %{kind => count}, &Map.put(&1, kind, count))
    end)
  end

  @doc "Deactivates discovered feeds the user has seen enough of but doesn't like."
  def prune_sources do
    recompute_like_rates()

    {count, _} =
      Repo.update_all(
        from(s in Subscription,
          where:
            s.origin == "discovered" and s.active == true and
              not is_nil(s.like_rate) and s.like_rate < @prune_threshold and
              fragment(
                "(SELECT count(*) FROM interactions i JOIN articles a ON a.id = i.article_id WHERE a.feed_id = ? AND i.user_id = ? AND i.kind = 'open') >= ?",
                s.feed_id,
                s.user_id,
                @prune_min_opens
              )
        ),
        set: [active: false]
      )

    count
  end

  # --- helpers ---

  # The site as it was supplied comes first: a feed advertised only at a path
  # (example.com/blog) can't be seen from the domain root.
  defp discover_feeds(%CandidateSource{site_url: nil, domain: domain}),
    do: FeedDiscoverer.discover(domain)

  defp discover_feeds(%CandidateSource{site_url: site_url, domain: domain}) do
    case FeedDiscoverer.discover(site_url) do
      {:ok, [_ | _]} = found -> found
      _ -> FeedDiscoverer.discover(domain)
    end
  end

  defp subscribe_discovered(feed_url, title, category) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Reader.upsert_feed(%{
      title: title,
      feed_url: feed_url,
      category: category,
      origin: "discovered",
      trust_score: 0.3,
      discovered_at: now
    })
  end

  defp upsert_candidate(domain, channel, article_id, mentions) do
    %CandidateSource{user_id: Repo.user_id!()}
    |> CandidateSource.changeset(%{
      domain: domain,
      channel: channel,
      discovered_from_article_id: article_id,
      mention_count: mentions
    })
    |> Repo.insert(
      on_conflict: [set: [mention_count: mentions]],
      conflict_target: [:user_id, :domain]
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

  # Domains the current user already subscribes to (catalog rows other users
  # own shouldn't block this user's discovery).
  defp existing_domains do
    Repo.all(
      from s in Subscription,
        join: f in Feed,
        on: f.id == s.feed_id,
        select: {f.site_url, f.feed_url}
    )
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

  defp normalize_domain(str) when is_binary(str) do
    case String.trim(str) do
      "" ->
        nil

      trimmed ->
        host =
          domain(if String.contains?(trimmed, "://"), do: trimmed, else: "https://#{trimmed}")

        # URI.parse takes "not a domain" as a host too
        if host && host =~ ~r/\A[a-z0-9-]+(\.[a-z0-9-]+)+\z/, do: host
    end
  end

  defp normalize_domain(_), do: nil

  defp domain(nil), do: nil

  defp domain(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host |> String.downcase() |> String.replace_prefix("www.", "")

      _ ->
        nil
    end
  end

  defp sum_kinds(rows, kinds), do: Enum.reduce(kinds, 0, &(&2 + Map.get(rows, &1, 0)))
end
