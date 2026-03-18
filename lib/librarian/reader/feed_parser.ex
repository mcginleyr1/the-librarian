defmodule Librarian.Reader.FeedParser do
  @moduledoc """
  Parses RSS 2.0, Atom, and RSS 1.0/RDF feeds into a common article shape.
  Returns a list of maps ready for Article.changeset/2.
  """

  def parse(body, feed_url) when is_binary(body) do
    case Saxy.SimpleForm.parse_string(body) do
      {:ok, doc} -> detect_and_parse(doc, feed_url)
      {:error, _} -> []
    end
  end

  defp detect_and_parse({tag, _attrs, _children} = doc, feed_url) do
    cond do
      tag in ["rss", "rdf:RDF"] -> parse_rss(doc, feed_url)
      tag == "feed" -> parse_atom(doc, feed_url)
      true -> []
    end
  end

  defp parse_rss({_tag, _attrs, children}, feed_url) do
    channel = find_child(children, "channel") || find_child(children, nil)

    items =
      ((channel && elem(channel, 2)) || children)
      |> Enum.filter(&match?({"item", _, _}, &1))

    Enum.map(items, fn {"item", _attrs, children} ->
      %{
        guid:
          text(children, "guid") || text(children, "link") || generate_guid(feed_url, children),
        title: text(children, "title"),
        url: text(children, "link"),
        summary: strip_html(text(children, "description")),
        content: text(children, "content:encoded"),
        author: text(children, "author") || text(children, "dc:creator"),
        published_at: parse_date(text(children, "pubDate") || text(children, "dc:date"))
      }
    end)
  end

  defp parse_atom({_tag, _attrs, children}, feed_url) do
    children
    |> Enum.filter(&match?({"entry", _, _}, &1))
    |> Enum.map(fn {"entry", _attrs, children} ->
      url = find_link(children)

      %{
        guid: text(children, "id") || url || generate_guid(feed_url, children),
        title: text(children, "title"),
        url: url,
        summary: strip_html(text(children, "summary")),
        content: text(children, "content"),
        author:
          get_in(find_child(children, "author"), [Access.elem(2)])
          |> then(fn c -> c && text(c, "name") end),
        published_at: parse_date(text(children, "published") || text(children, "updated"))
      }
    end)
  end

  defp find_child(children, tag) do
    Enum.find(children, fn
      {^tag, _, _} -> true
      _ -> false
    end)
  end

  # Saxy SimpleForm returns text content as plain strings in the children list,
  # not as {:characters, text} tuples.
  defp text(children, tag) do
    case find_child(children, tag) do
      {_, _, node_children} ->
        node_children
        |> Enum.filter(&is_binary/1)
        |> Enum.join()
        |> String.trim()
        |> then(fn s -> if s == "", do: nil, else: s end)

      _ ->
        nil
    end
  end

  defp find_link(children) do
    children
    |> Enum.find_value(fn
      {"link", attrs, _} ->
        rel = Enum.find_value(attrs, fn {k, v} -> if k == "rel", do: v end)
        href = Enum.find_value(attrs, fn {k, v} -> if k == "href", do: v end)
        if rel in [nil, "alternate"] and href, do: href

      _ ->
        nil
    end)
  end

  defp strip_html(nil), do: nil
  defp strip_html(html), do: HtmlSanitizeEx.strip_tags(html)

  defp parse_date(nil), do: nil

  defp parse_date(str) do
    with {:error, _} <- parse_rfc2822(str),
         {:error, _} <- DateTime.from_iso8601(str) do
      nil
    else
      {:ok, dt} -> DateTime.truncate(dt, :second)
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
    end
  end

  defp parse_rfc2822(str) do
    # :httpd_util expects "GMT" not "+0000" — normalize common UTC offsets
    normalized =
      str
      |> String.trim()
      |> String.replace(~r/\s*[+-]00:?00\s*$/, " GMT")
      |> String.to_charlist()

    case :httpd_util.convert_request_date(normalized) do
      :bad_date ->
        {:error, :bad_date}

      {{y, mo, d}, {h, mi, s}} ->
        case NaiveDateTime.new(y, mo, d, h, mi, s) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          err -> err
        end
    end
  rescue
    _ -> {:error, :parse_error}
  end

  defp generate_guid(feed_url, children) do
    :crypto.hash(:md5, feed_url <> inspect(children)) |> Base.encode16(case: :lower)
  end
end
