defmodule Librarian.Vault.Wikilink do
  @moduledoc """
  Obsidian-style `[[Note Title]]` links inside note bodies.

  Parsing is pure; resolution (title -> note id) lives in `Librarian.Vault`
  so tenancy applies. Rendering rewrites resolved links to `/vault/note/:id`
  anchors and leaves unresolved ones as literal text.
  """

  @pattern ~r/\[\[([^\[\]\n]+)\]\]/

  @doc "Unique trimmed titles referenced as `[[...]]` in the body."
  def extract_titles(nil), do: []

  def extract_titles(body) when is_binary(body) do
    @pattern
    |> Regex.scan(body)
    |> Enum.map(fn [_, title] -> String.trim(title) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Rewrites resolved `[[Title]]` occurrences to markdown links, for bodies
  that go through the markdown renderer. `targets` maps downcased title -> id.
  """
  def to_markdown_links(body, targets) when is_binary(body) do
    rewrite(body, targets, fn title, id -> "[#{title}](#{note_path(id)})" end)
  end

  @doc "Rewrites resolved `[[Title]]` occurrences to anchors, for HTML bodies."
  def to_html_links(body, targets) when is_binary(body) do
    rewrite(body, targets, fn title, id ->
      escaped = title |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
      ~s(<a href="#{note_path(id)}" class="wikilink">#{escaped}</a>)
    end)
  end

  defp rewrite(body, targets, link_fun) do
    Regex.replace(@pattern, body, fn whole, title ->
      title = String.trim(title)

      case Map.get(targets, String.downcase(title)) do
        nil -> whole
        id -> link_fun.(title, id)
      end
    end)
  end

  defp note_path(id), do: "/vault/note/#{id}"
end
