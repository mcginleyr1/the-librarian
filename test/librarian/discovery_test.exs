defmodule Librarian.DiscoveryTest do
  use Librarian.DataCase, async: true

  alias Librarian.{Discovery, Reader, Stream}
  alias Librarian.Reader.Article

  defp article_with_links(html) do
    {:ok, feed} =
      Reader.create_feed(%{
        title: "Aggregator",
        site_url: "https://news.ycombinator.com",
        feed_url: "https://news.ycombinator.com/rss-#{System.unique_integer([:positive])}"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Article{}
    |> Article.changeset(%{
      feed_id: feed.id,
      guid: "g-#{System.unique_integer([:positive])}",
      title: "Roundup",
      content: html,
      fetched_at: now
    })
    |> Repo.insert!()
  end

  test "extract_domains pulls normalized hosts from anchor tags" do
    html = ~s(<a href="https://www.jepsen.io/post">x</a> <a href="https://fly.io/blog">y</a>)
    assert Discovery.extract_domains(html) == ["jepsen.io", "fly.io"]
  end

  test "harvest_link_graph creates candidates from liked articles, excluding known domains" do
    article =
      article_with_links(~s(
        <a href="https://jepsen.io/analyses">a</a>
        <a href="https://news.ycombinator.com/item">self</a>
      ))

    Stream.record_interaction(article.id, :like)
    Discovery.harvest_link_graph()

    candidates = Discovery.list_candidates()
    domains = Enum.map(candidates, & &1.domain)

    assert "jepsen.io" in domains
    # the source's own domain is excluded (already a known feed)
    refute "news.ycombinator.com" in domains
  end

  test "harvest_aggregators mines outbound domains from aggregator feeds without needing a like" do
    _article =
      article_with_links(~s(<a href="https://danluu.com/post">deep dive</a>))

    # no interaction at all — aggregator mining is interaction-independent
    Discovery.harvest_aggregators()

    domains = Discovery.list_candidates() |> Enum.map(& &1.domain)
    assert "danluu.com" in domains

    candidate = Discovery.list_candidates() |> Enum.find(&(&1.domain == "danluu.com"))
    assert candidate.channel == "aggregator"
  end

  test "prune leaves engaged feeds alone" do
    article = article_with_links("<p>no links</p>")
    Stream.record_interaction(article.id, :like)
    assert Discovery.prune_sources() == 0
  end
end
