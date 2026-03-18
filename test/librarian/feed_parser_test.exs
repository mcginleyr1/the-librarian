defmodule Librarian.Reader.FeedParserTest do
  use ExUnit.Case, async: true

  alias Librarian.Reader.FeedParser

  @rss2 File.read!("test/fixtures/rss2.xml")
  @atom File.read!("test/fixtures/atom.xml")

  describe "parse/2 with RSS 2.0" do
    setup do
      %{articles: FeedParser.parse(@rss2, "https://example.com/feed")}
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
      %{articles: FeedParser.parse(@atom, "https://example.com/feed")}
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
    test "returns empty list for invalid XML" do
      assert [] == FeedParser.parse("not xml at all", "https://example.com")
    end

    test "returns empty list for empty string" do
      assert [] == FeedParser.parse("", "https://example.com")
    end
  end
end
