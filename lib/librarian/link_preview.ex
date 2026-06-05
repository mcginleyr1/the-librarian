defmodule Librarian.LinkPreview do
  @moduledoc """
  Derives a link-preview "graph card" for an article from data already on hand:
  Open Graph / Twitter meta tags if the stored HTML has them, otherwise the lead
  image and first paragraph of the content, the feed as the site name, and the
  domain's favicon. Returns `nil` when there's nothing worth showing.
  """

  alias Librarian.Reader.{Article, Feed}

  @max_description 200

  @doc "Returns a preview map for an article, or `nil` if no useful metadata exists."
  def for_article(%Article{} = article) do
    doc = parse(article.content)

    image =
      resolve(meta(doc, "og:image") || meta(doc, "twitter:image") || first_img(doc), article.url)

    description = clean(article.summary) || meta(doc, "og:description") || first_paragraph(doc)
    site_name = meta(doc, "og:site_name") || feed_title(article.feed)
    domain = domain(article.url)

    if image || present?(description) do
      %{
        image: image,
        description: truncate(description),
        site_name: site_name,
        domain: domain,
        favicon: favicon(domain)
      }
    end
  end

  defp parse(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} -> doc
      _ -> []
    end
  end

  defp parse(_), do: []

  defp meta(doc, property) do
    value =
      doc
      |> Floki.find(~s(meta[property="#{property}"], meta[name="#{property}"]))
      |> Floki.attribute("content")
      |> List.first()

    if present?(value), do: String.trim(value)
  end

  defp first_img(doc) do
    doc |> Floki.attribute("img", "src") |> List.first()
  end

  defp first_paragraph(doc) do
    doc
    |> Floki.find("p")
    |> Enum.map(&Floki.text/1)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(String.length(&1) > 20))
  end

  defp feed_title(%Feed{title: title}), do: title
  defp feed_title(_), do: nil

  defp resolve(nil, _base), do: nil

  defp resolve(url, base) do
    case URI.parse(url) do
      %URI{scheme: s} when s in ["http", "https", "data"] -> url
      _ when is_binary(base) -> base |> URI.merge(url) |> to_string()
      _ -> nil
    end
  end

  defp domain(nil), do: nil

  defp domain(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "www.", "")
      _ -> nil
    end
  end

  defp favicon(nil), do: nil
  defp favicon(domain), do: "https://icons.duckduckgo.com/ip3/#{domain}.ico"

  defp clean(nil), do: nil

  defp clean(text) do
    stripped = text |> HtmlSanitizeEx.strip_tags() |> String.trim()
    if stripped == "", do: nil, else: stripped
  end

  defp truncate(nil), do: nil

  defp truncate(text) do
    if String.length(text) > @max_description do
      String.slice(text, 0, @max_description) <> "…"
    else
      text
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
