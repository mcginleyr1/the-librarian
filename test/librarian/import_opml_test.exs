defmodule Librarian.ImportOpmlTest do
  use Librarian.DataCase, async: true

  alias Librarian.Reader
  alias Librarian.Reader.Feed

  @fixture Path.expand("../fixtures/sample.opml", __DIR__)

  describe "upsert_feed/1" do
    test "inserts a new feed" do
      attrs = %{
        title: "Lambda the Ultimate",
        feed_url: "http://lambda-the-ultimate.org/rss.xml",
        site_url: "http://lambda-the-ultimate.org",
        category: "Tech"
      }

      assert {:ok, %Feed{id: id}} = Reader.upsert_feed(attrs)
      assert is_integer(id)
    end

    test "is idempotent on duplicate feed_url" do
      attrs = %{
        title: "Lambda the Ultimate",
        feed_url: "http://lambda-the-ultimate.org/rss.xml",
        site_url: "http://lambda-the-ultimate.org",
        category: "Tech"
      }

      assert {:ok, %Feed{id: id1}} = Reader.upsert_feed(attrs)
      assert {:ok, %Feed{id: nil}} = Reader.upsert_feed(attrs)

      feeds = Repo.all(Feed)
      assert length(feeds) == 1
      assert hd(feeds).id == id1
    end
  end

  describe "OPML parsing and import" do
    test "imports 3 unique feeds from the sample file" do
      feeds = parse_opml_feeds(@fixture)

      {imported, _skipped} = import_feeds(feeds)

      assert imported == 3
      assert Repo.aggregate(Feed, :count) == 3
    end

    test "skips the duplicate feed" do
      feeds = parse_opml_feeds(@fixture)
      {_imported, skipped} = import_feeds(feeds)

      assert skipped == 1
    end

    test "imported feed has correct title and feed_url" do
      feeds = parse_opml_feeds(@fixture)
      import_feeds(feeds)

      feed = Repo.get_by(Feed, feed_url: "http://lambda-the-ultimate.org/rss.xml")
      assert feed != nil
      assert feed.title == "Lambda the Ultimate"
      assert feed.category == "Tech"
    end

    test "imported feed has correct site_url" do
      feeds = parse_opml_feeds(@fixture)
      import_feeds(feeds)

      feed = Repo.get_by(Feed, feed_url: "http://lambda-the-ultimate.org/rss.xml")
      assert feed.site_url == "http://lambda-the-ultimate.org"
    end

    test "running import twice is idempotent" do
      feeds = parse_opml_feeds(@fixture)
      import_feeds(feeds)
      import_feeds(feeds)

      assert Repo.aggregate(Feed, :count) == 3
    end
  end

  defp parse_opml_feeds(file_path) do
    {:ok, {"opml", _attrs, opml_children}} =
      Saxy.SimpleForm.parse_string(File.read!(file_path))

    {"body", _attrs, outlines} =
      Enum.find(opml_children, fn
        {"body", _, _} -> true
        _ -> false
      end)

    extract_feeds(outlines)
  end

  defp extract_feeds(outlines) do
    Enum.flat_map(outlines, fn
      {"outline", attrs, children} ->
        case get_attr(attrs, "xmlUrl") do
          nil ->
            category = get_attr(attrs, "text") || "Uncategorized"
            extract_feeds_with_category(children, category)

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp extract_feeds_with_category(outlines, category) do
    Enum.flat_map(outlines, fn
      {"outline", attrs, _children} ->
        case get_attr(attrs, "xmlUrl") do
          nil ->
            []

          feed_url ->
            if String.contains?(feed_url, "feedly.com/f/alert") do
              []
            else
              title = get_attr(attrs, "title") || get_attr(attrs, "text") || feed_url

              [
                %{
                  title: title,
                  feed_url: feed_url,
                  site_url: get_attr(attrs, "htmlUrl"),
                  category: category
                }
              ]
            end
        end

      _ ->
        []
    end)
  end

  defp import_feeds(feeds) do
    Enum.reduce(feeds, {0, 0}, fn attrs, {imported, skipped} ->
      case Reader.upsert_feed(attrs) do
        {:ok, %{id: nil}} -> {imported, skipped + 1}
        {:ok, _feed} -> {imported + 1, skipped}
        {:error, _changeset} -> {imported, skipped + 1}
      end
    end)
  end

  defp get_attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end
end
