defmodule Librarian.Reader.FeedDiscoverer do
  @common_paths ["/feed", "/rss", "/feed.xml", "/atom.xml", "/rss.xml", "/feeds/posts/default"]

  @doc """
  Given any URL (website or direct feed URL), returns a list of discovered feeds.
  Each feed is %{url: url, title: title}.
  """
  def discover(raw_url) do
    url = normalize_url(raw_url)

    case Req.get(url, receive_timeout: 10_000, redirect: true) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        if feed_response?(headers) do
          {:ok, [%{url: url, title: extract_xml_title(body) || url}]}
        else
          links = find_links_in_html(body, url)

          if links != [] do
            {:ok, links}
          else
            {:ok, probe_common_paths(url)}
          end
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp normalize_url(url) do
    url = String.trim(url)
    if String.starts_with?(url, "http"), do: url, else: "https://#{url}"
  end

  defp feed_response?(headers) do
    ct = headers |> Map.get("content-type", []) |> List.wrap() |> List.first() || ""
    String.contains?(ct, "xml") or String.contains?(ct, "rss") or String.contains?(ct, "atom")
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
        |> Enum.map(fn el ->
          href = el |> Floki.attribute("href") |> List.first()
          title = el |> Floki.attribute("title") |> List.first()
          if href, do: %{url: resolve_url(href, base_url), title: title || href}
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp probe_common_paths(url) do
    base =
      case URI.parse(url) do
        %{scheme: s, host: h} when is_binary(h) -> "#{s}://#{h}"
        _ -> url
      end

    @common_paths
    |> Task.async_stream(
      fn path ->
        candidate = base <> path

        case Req.get(candidate, receive_timeout: 4_000, redirect: true) do
          {:ok, %{status: 200, body: body, headers: headers}} ->
            if feed_response?(headers) do
              %{url: candidate, title: extract_xml_title(body) || candidate}
            end

          _ ->
            nil
        end
      end,
      timeout: :infinity,
      max_concurrency: length(@common_paths)
    )
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, feed} -> [feed]
      _ -> []
    end)
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
