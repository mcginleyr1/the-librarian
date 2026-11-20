defmodule Librarian.Reader.FeedParserTest do
  use ExUnit.Case, async: true

  alias Librarian.Reader.FeedParser

  @rss2 File.read!("test/fixtures/rss2.xml")
  @atom File.read!("test/fixtures/atom.xml")

  describe "parse/2 with RSS 1.0 (RDF)" do
    test "reads items that sit beside the channel" do
      rdf = """
      <?xml version="1.0"?>
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
               xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <channel rdf:about="https://example.com/"><title>RDF Feed</title></channel>
        <item rdf:about="https://example.com/1">
          <title>RDF One</title>
          <link>https://example.com/1</link>
          <dc:date>2026-03-18T10:00:00Z</dc:date>
        </item>
      </rdf:RDF>
      """

      assert {:ok, [%{title: "RDF One", url: "https://example.com/1"}]} =
               FeedParser.parse(rdf, "https://example.com/rdf")
    end
  end

  describe "parse/2 content fallback" do
    test "uses the raw description as content when content:encoded is absent" do
      rss = """
      <rss version="2.0"><channel><title>T</title>
        <item><title>One</title><link>https://e.com/1</link>
          <description>&lt;p&gt;Hi &lt;a href="https://e.com"&gt;link&lt;/a&gt;&lt;/p&gt;</description>
        </item>
      </channel></rss>
      """

      assert {:ok, [article]} = FeedParser.parse(rss, "https://e.com/feed")
      assert article.content == ~s(<p>Hi <a href="https://e.com">link</a></p>)
      assert article.summary == "Hi link"
    end
  end

  describe "parse/2 with RSS 2.0" do
    setup do
      {:ok, articles} = FeedParser.parse(@rss2, "https://example.com/feed")
      %{articles: articles}
    end

    test "returns two articles", %{articles: articles} do
      assert length(articles) == 2
    end

    test "extracts title", %{articles: [first | _]} do
      assert first.title == "First Post"
    end

    test "extracts guid", %{articles: [first | _]} do
      assert first.guid == "https://example.com/post-1"
    end

    test "extracts url", %{articles: [first | _]} do
      assert first.url == "https://example.com/post-1"
    end

    test "strips html from description", %{articles: [first | _]} do
      assert first.summary == "Summary of first post."
    end

    test "extracts author", %{articles: [first | _]} do
      assert first.author == "alice@example.com"
    end

    test "parses pubDate into DateTime", %{articles: [first | _]} do
      assert %DateTime{year: 2026, month: 3, day: 18} = first.published_at
    end

    test "second article has no author", %{articles: [_, second]} do
      assert is_nil(second.author)
    end
  end

  describe "parse/2 with Atom" do
    setup do
      {:ok, articles} = FeedParser.parse(@atom, "https://example.com/feed")
      %{articles: articles}
    end

    test "returns two entries", %{articles: articles} do
      assert length(articles) == 2
    end

    test "extracts id as guid", %{articles: [first | _]} do
      assert first.guid == "https://example.com/atom-1"
    end

    test "extracts link from rel=alternate", %{articles: [first | _]} do
      assert first.url == "https://example.com/atom-1"
    end

    test "extracts summary", %{articles: [first | _]} do
      assert first.summary == "Summary of atom entry one."
    end

    test "extracts author name", %{articles: [first | _]} do
      assert first.author == "Bob"
    end

    test "parses published as DateTime", %{articles: [first | _]} do
      assert %DateTime{year: 2026, month: 3, day: 18, hour: 12} = first.published_at
    end

    test "second entry uses href link without rel", %{articles: [_, second]} do
      assert second.url == "https://example.com/atom-2"
    end

    test "extracts content on second entry", %{articles: [_, second]} do
      assert second.content == "Full content of atom entry two."
    end

    test "second entry falls back to updated when no published", %{articles: [_, second]} do
      assert %DateTime{year: 2026, month: 3, day: 19} = second.published_at
    end
  end

  describe "parse/2 with bad input" do
    test "returns error for invalid XML" do
      assert {:error, _} = FeedParser.parse("not xml at all", "https://example.com")
    end

    test "returns error for empty string" do
      assert {:error, _} = FeedParser.parse("", "https://example.com")
    end

    test "returns error for XML that is not a feed" do
      assert {:error, "unrecognized feed root <html>"} =
               FeedParser.parse("<html></html>", "https://example.com")
    end

    test "parses a feed with a UTF-8 BOM prefix" do
      assert {:ok, articles} = FeedParser.parse("\uFEFF" <> @atom, "https://example.com/feed")
      assert length(articles) == 2
    end

    test "parses a feed with markup appended after the closing root tag" do
      junk =
        ~s(<script>var beacon = "</rss></feed>"</script><script src='beacon.js' async></script>)

      assert {:ok, articles} = FeedParser.parse(@rss2 <> junk, "https://example.com/feed")
      assert length(articles) == 2
    end

    test "returns error for a non-feed page with markup after its first element" do
      assert {:error, "unrecognized feed root <br>"} =
               FeedParser.parse("<br />\n<b>Warning</b> </rss>", "https://example.com")
    end
  end

  test "applies non-UTC RFC 2822 offsets instead of dropping them" do
    rss =
      String.replace(@rss2, "Wed, 18 Mar 2026 10:00:00 +0000", "Wed, 18 Mar 2026 10:00:00 -0500")

    {:ok, [first | _]} = FeedParser.parse(rss, "https://example.com/feed")
    assert first.published_at == ~U[2026-03-18 15:00:00Z]
  end
end
