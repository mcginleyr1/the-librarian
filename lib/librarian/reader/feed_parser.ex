defmodule Librarian.Reader.FeedParser do
  @moduledoc """
  Parses RSS 2.0, Atom, and RSS 1.0/RDF feeds into a common article shape.
  Returns `{:ok, articles}` (maps ready for Article.changeset/2) or
  `{:error, message}` when the body is not a recognizable feed.
  """

  @behaviour Saxy.Handler

  def parse(body, feed_url) when is_binary(body) do
    case Saxy.parse_string(String.replace_prefix(body, "\uFEFF", ""), __MODULE__, []) do
      {:ok, {tag, _, _} = doc} when tag in ["rss", "rdf:RDF"] -> {:ok, parse_rss(doc, feed_url)}
      {:ok, {"feed", _, _} = doc} -> {:ok, parse_atom(doc, feed_url)}
      {:ok, {tag, _, _}} -> {:error, "unrecognized feed root <#{tag}>"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # Builds Saxy's simple form but stops at the root's closing tag: some sites
  # append markup after it (WP Rocket adds <script> tags to feeds), which a
  # full parse rejects as not well-formed.
  @impl Saxy.Handler
  def handle_event(event, data, stack) do
    with {:ok, root} when is_tuple(root) <-
           Saxy.SimpleForm.Handler.handle_event(event, data, stack),
         do: {:stop, root}
  end

  defp parse_rss({_tag, _attrs, children}, feed_url) do
    channel = find_child(children, "channel")

    for {"item", _attrs, children} <- (channel && elem(channel, 2)) || children do
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
    end
  end

  defp parse_atom({_tag, _attrs, children}, feed_url) do
    for {"entry", _attrs, children} <- children do
      url = find_link(children)

      %{
        guid: text(children, "id") || url || generate_guid(feed_url, children),
        title: text(children, "title"),
        url: url,
        summary: strip_html(text(children, "summary")),
        content: text(children, "content"),
        author: with({_, _, author} <- find_child(children, "author"), do: text(author, "name")),
        published_at: parse_date(text(children, "published") || text(children, "updated"))
      }
    end
  end

  defp find_child(children, tag), do: Enum.find(children, &match?({^tag, _, _}, &1))

  # Saxy SimpleForm returns text content as plain strings in the children list,
  # not as {:characters, text} tuples.
  defp text(children, tag) do
    with {_, _, nodes} <- find_child(children, tag),
         string when string != "" <-
           nodes |> Enum.filter(&is_binary/1) |> Enum.join() |> String.trim() do
      string
    else
      _ -> nil
    end
  end

  defp find_link(children) do
    Enum.find_value(children, fn
      {"link", attrs, _} ->
        {_, rel} = List.keyfind(attrs, "rel", 0, {"rel", nil})
        {_, href} = List.keyfind(attrs, "href", 0, {"href", nil})
        if rel in [nil, "alternate"], do: href

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
    # :httpd_util wants "GMT" and silently ignores numeric offsets ("-0500"
    # parses as if it were GMT), so strip the offset and apply it ourselves.
    {base, offset_seconds} =
      case Regex.run(~r/^(.*?)\s*([+-])(\d{2}):?(\d{2})$/, String.trim(str)) do
        [_, base, sign, hh, mm] ->
          seconds = (String.to_integer(hh) * 60 + String.to_integer(mm)) * 60
          {base <> " GMT", if(sign == "-", do: -seconds, else: seconds)}

        nil ->
          {String.trim(str), 0}
      end

    case :httpd_util.convert_request_date(String.to_charlist(base)) do
      :bad_date ->
        {:error, :bad_date}

      {{y, mo, d}, {h, mi, s}} ->
        with {:ok, ndt} <- NaiveDateTime.new(y, mo, d, h, mi, s) do
          {:ok, ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-offset_seconds)}
        end
    end
  rescue
    _ -> {:error, :parse_error}
  end

  defp generate_guid(feed_url, children) do
    :crypto.hash(:md5, feed_url <> inspect(children)) |> Base.encode16(case: :lower)
  end
end
