defmodule Librarian.LinkPreviewTest do
  use Librarian.DataCase, async: true

  alias Librarian.LinkPreview
  alias Librarian.Reader.{Article, Feed}

  defp article(attrs) do
    feed = %Feed{title: "Fly.io Blog"}
    struct(Article, Map.merge(%{url: "https://fly.io/blog/post", feed: feed}, attrs))
  end

  test "prefers og:image and og:description meta tags" do
    html = ~s(
      <meta property="og:image" content="https://fly.io/cover.png" />
      <meta property="og:description" content="A deep dive into distributed Postgres." />
      <p>body</p>
    )

    preview = LinkPreview.for_article(article(%{content: html}))
    assert preview.image == "https://fly.io/cover.png"
    assert preview.description == "A deep dive into distributed Postgres."
    assert preview.domain == "fly.io"
    assert preview.favicon =~ "fly.io"
  end

  test "falls back to lead image and first paragraph from content" do
    html =
      ~s(<img src="https://fly.io/lead.jpg"><p>The first meaningful paragraph of the article body.</p>)

    preview = LinkPreview.for_article(article(%{content: html}))

    assert preview.image == "https://fly.io/lead.jpg"
    assert preview.description =~ "first meaningful paragraph"
    assert preview.site_name == "Fly.io Blog"
  end

  test "returns nil when there is no usable metadata" do
    assert LinkPreview.for_article(article(%{content: nil, summary: nil})) == nil
    assert LinkPreview.for_article(article(%{content: "<div></div>", summary: nil})) == nil
  end

  test "resolves relative image URLs against the article url" do
    preview =
      LinkPreview.for_article(
        article(%{content: ~s(<img src="/img/x.png"><p>enough text to count here</p>)})
      )

    assert preview.image == "https://fly.io/img/x.png"
  end
end
