defmodule Mix.Tasks.Librarian.ImportOpml do
  use Mix.Task

  @shortdoc "Import feeds from an OPML file"

  @impl Mix.Task
  def run([file_path]) do
    Mix.Task.run("app.start")

    contents = File.read!(file_path)

    case Saxy.SimpleForm.parse_string(contents) do
      {:ok, {"opml", _attrs, opml_children}} ->
        body = find_child(opml_children, "body")

        case body do
          {"body", _attrs, outlines} ->
            feeds = extract_feeds(outlines)
            {imported, skipped} = import_feeds(feeds)

            categories =
              feeds
              |> Enum.map(& &1.category)
              |> Enum.uniq()
              |> length()

            Mix.shell().info(
              "Imported #{imported} feeds across #{categories} categories (#{skipped} skipped as duplicates)"
            )

          nil ->
            Mix.shell().error("No <body> element found in OPML file")
        end

      {:ok, _other} ->
        Mix.shell().error("File does not appear to be a valid OPML document")

      {:error, reason} ->
        Mix.shell().error("Failed to parse OPML: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.shell().error("Usage: mix librarian.import_opml <file_path>")

  defp extract_feeds(outlines) do
    Enum.flat_map(outlines, fn
      {tag, attrs, children} when tag == "outline" ->
        case get_attr(attrs, "xmlUrl") do
          nil ->
            category = get_attr(attrs, "text") || get_attr(attrs, "title") || "Uncategorized"
            extract_feeds_with_category(children, category)

          _url ->
            []
        end

      _ ->
        []
    end)
  end

  defp extract_feeds_with_category(outlines, category) do
    Enum.flat_map(outlines, fn
      {"outline", attrs, _children} ->
        feed_url = get_attr(attrs, "xmlUrl")

        cond do
          is_nil(feed_url) ->
            []

          String.contains?(feed_url, "feedly.com/f/alert") ->
            []

          true ->
            title = get_attr(attrs, "title") || get_attr(attrs, "text") || feed_url
            site_url = get_attr(attrs, "htmlUrl")

            [%{title: title, feed_url: feed_url, site_url: site_url, category: category}]
        end

      _ ->
        []
    end)
  end

  defp import_feeds(feeds) do
    Enum.reduce(feeds, {0, 0}, fn attrs, {imported, skipped} ->
      case Librarian.Reader.upsert_feed(attrs) do
        {:ok, %{id: nil}} -> {imported, skipped + 1}
        {:ok, _feed} -> {imported + 1, skipped}
        {:error, _changeset} -> {imported, skipped + 1}
      end
    end)
  end

  defp find_child(children, tag) do
    Enum.find(children, fn
      {^tag, _, _} -> true
      _ -> false
    end)
  end

  defp get_attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end
end
