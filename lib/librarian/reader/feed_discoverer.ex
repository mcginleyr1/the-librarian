defmodule Librarian.Reader.FeedDiscoverer do
  @moduledoc """
  Finds the RSS/Atom feeds behind a URL: the URL itself if it serves a feed,
  else the page's `<link rel="alternate">` feeds, else whatever answers at a
  few common feed paths. Every request goes through `Librarian.SafeHTTP`.
  """

  @common_paths ["/feed", "/rss", "/feed.xml", "/atom.xml", "/rss.xml", "/feeds/posts/default"]

  @doc """
  Given any URL (website or direct feed URL), returns a list of discovered feeds.
  Each feed is %{url: url, title: title}.
  """
  def discover(raw_url) do
    url = normalize_url(raw_url)

    case Librarian.SafeHTTP.get(url, receive_timeout: 10_000, deadline_ms: 20_000) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        {:ok, feeds_from_page(url, body, headers)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp feeds_from_page(url, body, headers) do
    if feed_response?(headers) do
      [%{url: url, title: extract_xml_title(body) || url}]
    else
      case find_links_in_html(body, url) do
        [] -> probe_common_paths(url)
        links -> links
      end
    end
  end

  defp normalize_url(url) do
    url = String.trim(url)
    if URI.parse(url).scheme in ["http", "https"], do: url, else: "https://#{url}"
  end

  defp feed_response?(headers) do
    ct = headers |> Map.get("content-type", []) |> List.wrap() |> List.first() || ""

    not String.contains?(ct, "xhtml") and
      (String.contains?(ct, "xml") or String.contains?(ct, "rss") or String.contains?(ct, "atom"))
  end

  defp find_links_in_html(body, base_url) do
    case Floki.parse_document(body) do
      {:ok, doc} ->
        doc
        |> Floki.find("link[rel=alternate]")
        |> Enum.filter(fn el ->
          type = el |> Floki.attribute("type") |> List.first() || ""
          type in ["application/rss+xml", "application/atom+xml"]
        end)
        |> Enum.map(&feed_link(&1, base_url))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp feed_link(el, base_url) do
    href = el |> Floki.attribute("href") |> List.first()
    title = el |> Floki.attribute("title") |> List.first()
    if href, do: %{url: resolve_url(href, base_url), title: title || href}
  end

  defp probe_common_paths(url) do
    base =
      case URI.parse(url) do
        %{scheme: s, host: h} when is_binary(h) -> "#{s}://#{h}"
        _ -> url
      end

    @common_paths
    |> Task.async_stream(&probe_feed(base <> &1),
      timeout: :infinity,
      max_concurrency: length(@common_paths)
    )
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, feed} -> [feed]
      _ -> []
    end)
  end

  defp probe_feed(candidate) do
    case Librarian.SafeHTTP.get(candidate, receive_timeout: 4_000, deadline_ms: 8_000) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        if feed_response?(headers) do
          %{url: candidate, title: extract_xml_title(body) || candidate}
        end

      _ ->
        nil
    end
  end

  defp extract_xml_title(body) do
    case Saxy.SimpleForm.parse_string(body) do
      {:ok, {_, _, children}} -> find_title(children)
      _ -> nil
    end
  end

  defp find_title([]), do: nil

  defp find_title([{"channel", _, ch} | _]), do: find_title(ch)
  defp find_title([{"title", _, [t | _]} | _]) when is_binary(t), do: String.trim(t)
  defp find_title([_ | rest]), do: find_title(rest)

  defp resolve_url(href, base_url) do
    case URI.parse(href) do
      %{scheme: s} when s in ["http", "https"] -> href
      _ -> URI.merge(URI.parse(base_url), href) |> to_string()
    end
  end
end
