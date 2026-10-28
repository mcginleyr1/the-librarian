defmodule LibrarianWeb.McpTools do
  @moduledoc """
  The tools the MCP server (`LibrarianWeb.McpController`) exposes. They run in
  the request process, so the Repo tenant set by the API token plug scopes
  every query: another user's note or article looks exactly like a missing one.
  """
  use LibrarianWeb, :verified_routes

  alias Librarian.{Reader, Vault}
  alias LibrarianWeb.NoteApiController

  @default_limit 50
  @max_limit 200

  @limit %{
    type: "integer",
    minimum: 1,
    maximum: @max_limit,
    description: "Maximum results (default #{@default_limit})."
  }
  @read_only %{readOnlyHint: true, openWorldHint: false}

  @tools [
    %{
      name: "search_notes",
      title: "Search notes",
      description: """
      Search the user's own note vault: markdown notes, web clips and saved PDFs. \
      Use it whenever the user mentions something they wrote, saved, clipped or \
      "have notes on", or when their notes could answer the question. Title \
      matches come first, then full-text matches. Returns note summaries (id, \
      title, notebook, tags, source_url, updated_at); call read_note for a \
      note's text. Without a query, lists the most recently updated notes.\
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Words to look for in titles and text."},
          limit: @limit,
          notebook_id: %{
            type: "integer",
            description: "Only search this notebook (ids from list_notebooks)."
          }
        },
        additionalProperties: false
      },
      annotations: @read_only
    },
    %{
      name: "read_note",
      title: "Read note",
      description: """
      Read one note from the user's vault in full: title, tags, notebook, \
      source_url, body, and its connections to other notes (wiki-links and \
      related notes, which you can read in turn). Use it after search_notes \
      when you need what a note actually says. Markdown notes come back as \
      written; web clips are converted from HTML to markdown. A note backed by \
      a stored file (PDF, screenshot, page snapshot) lists it under "file" and \
      may have an empty body.\
      """,
      inputSchema: %{
        type: "object",
        properties: %{id: %{type: "integer", description: "The note id."}},
        required: ["id"],
        additionalProperties: false
      },
      annotations: @read_only
    },
    %{
      name: "list_notebooks",
      title: "List notebooks",
      description: """
      List the notebooks the user files notes into (id and name). Use it to \
      find a notebook_id for search_notes or save_note.\
      """,
      inputSchema: %{type: "object", additionalProperties: false},
      annotations: @read_only
    },
    %{
      name: "save_note",
      title: "Save note",
      description: """
      Write a markdown note into the user's vault. Use it only when the user \
      asks you to write something down, save, remember or file it. Without \
      external_id every call creates a new note. With external_id, a stable id \
      you choose for the note (prefix it with your own name so it can't clash \
      with other clients), the first call creates the note and later calls \
      overwrite that same note, so one note can be kept up to date instead of \
      piling up copies. [[Note Title]] in the body links to another note.\
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          title: %{type: "string"},
          body: %{type: "string", description: "Markdown."},
          tags: %{
            type: "array",
            items: %{type: "string"},
            description: "Replaces the note's tags when given."
          },
          notebook_id: %{
            type: "integer",
            description: "File the note in this notebook (ids from list_notebooks)."
          },
          source_url: %{type: "string", description: "Where the content came from."},
          external_id: %{
            type: "string",
            description: "Your stable id for this note; saving again overwrites it."
          }
        },
        required: ["title", "body"],
        additionalProperties: false
      },
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: false
      }
    },
    %{
      name: "search_articles",
      title: "Search articles",
      description: """
      Full-text search (titles and summaries) of the articles in the RSS feeds \
      the user follows, plus any they starred. Use it when the user asks about \
      something they read or may have seen in their feeds, blogs, news or \
      newsletters. Returns article summaries (id, title, feed, url, author, \
      published_at, summary); call read_article for the full text.\
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Words to look for."},
          limit: @limit
        },
        required: ["query"],
        additionalProperties: false
      },
      annotations: @read_only
    },
    %{
      name: "read_article",
      title: "Read article",
      description: """
      Read one RSS article in full, converted from HTML to markdown, with its \
      feed, url, author and publish date. Use it after search_articles when \
      you need what an article actually says.\
      """,
      inputSchema: %{
        type: "object",
        properties: %{id: %{type: "integer", description: "The article id."}},
        required: ["id"],
        additionalProperties: false
      },
      annotations: @read_only
    }
  ]

  def list, do: @tools

  @doc """
  Runs a tool. Returns `{:ok, result}` (JSON-encodable), `{:error, message}`
  for a failure the model can correct, or `:unknown_tool`.
  """
  def call("search_notes", args) do
    with {:ok, query} <- fetch(args, "query", :string),
         {:ok, limit} <- limit(args),
         {:ok, notebook_id} <- fetch(args, "notebook_id", :integer) do
      notes = Vault.find_notes(query || "", limit, notebook_id)
      {:ok, %{notes: Enum.map(notes, &NoteApiController.summary/1)}}
    end
  end

  def call("read_note", args) do
    with {:ok, id} <- fetch(args, "id", :integer, :required),
         %Vault.Note{} = note <- Vault.get_note(id) || {:error, "Note #{id} not found"} do
      file =
        note.storage_key &&
          %{url: ~p"/api/notes/#{note.id}/file", content_type: MIME.from_path(note.storage_key)}

      note_body =
        if note.clip_mode == "markdown" or is_nil(note.body),
          do: note.body,
          else: html_to_markdown(note.body)

      {:ok,
       %{
         note:
           Map.merge(NoteApiController.summary(note), %{
             body: note_body,
             file: file,
             related: NoteApiController.related(note)
           })
       }}
    end
  end

  def call("list_notebooks", _args) do
    {:ok, %{notebooks: Enum.map(Vault.list_notebooks(), &%{id: &1.id, name: &1.name})}}
  end

  def call("save_note", args) do
    with {:ok, _title} <- fetch(args, "title", :string, :required),
         {:ok, _body} <- fetch(args, "body", :string, :required),
         {:ok, tags} <- fetch(args, "tags", :strings),
         {:ok, _notebook_id} <- fetch(args, "notebook_id", :integer),
         {:ok, _source_url} <- fetch(args, "source_url", :string),
         {:ok, external_id} <- fetch(args, "external_id", :string),
         attrs = Map.take(args, ~w(title body notebook_id source_url)),
         {:ok, note, created?} <- save_note(external_id, attrs, tags) do
      {:ok, %{id: note.id, title: note.title, created: created?}}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(
            changeset,
            &LibrarianWeb.CoreComponents.translate_error/1
          )

        {:error,
         Enum.map_join(errors, "; ", fn {field, messages} ->
           "#{field} #{Enum.join(messages, ", ")}"
         end)}

      error ->
        error
    end
  end

  def call("search_articles", args) do
    with {:ok, query} <- fetch(args, "query", :string, :required),
         {:ok, limit} <- limit(args) do
      articles = Reader.search_articles(query, limit: limit)
      {:ok, %{articles: Enum.map(articles, &article_summary/1)}}
    end
  end

  def call("read_article", args) do
    with {:ok, id} <- fetch(args, "id", :integer, :required),
         %Reader.Article{} = article <-
           Reader.get_article(id) || {:error, "Article #{id} not found"} do
      content = html_to_markdown(article.content || article.summary || "")
      {:ok, %{article: Map.put(article_summary(article), :content, content)}}
    end
  end

  def call(_name, _args), do: :unknown_tool

  # Same paths as the REST API: a plain create, or the editor-sync upsert
  # keyed by external_id (`PUT /api/notes/external/:external_id`). Both
  # rebuild the note's wiki-link edges.
  defp save_note(nil, attrs, tags) do
    with {:ok, note} <- Vault.create_note(Map.put(attrs, "clip_mode", "markdown"), tags || []),
         do: {:ok, note, true}
  end

  defp save_note(external_id, attrs, tags), do: Vault.sync_note(external_id, attrs, tags)

  defp article_summary(article) do
    %{
      id: article.id,
      title: article.title,
      feed: article.feed.title,
      url: article.url,
      author: article.author,
      published_at: article.published_at,
      summary: article.summary && String.slice(article.summary, 0, 300)
    }
  end

  # Same bounds as `GET /api/notes`: default 50, at most 200.
  defp limit(args) do
    with {:ok, limit} <- fetch(args, "limit", :integer),
         do: {:ok, if(limit && limit > 0, do: min(limit, @max_limit), else: @default_limit)}
  end

  # Models fill optional fields with "" as often as they leave them out.
  defp fetch(args, key, type, required \\ :optional) do
    case {Map.get(args, key), type} do
      {blank, _type} when blank in [nil, ""] and required == :optional -> {:ok, nil}
      {blank, _type} when blank in [nil, ""] -> {:error, "#{key} is required"}
      {value, :string} when is_binary(value) -> {:ok, value}
      {value, :integer} when is_integer(value) -> {:ok, value}
      {value, :strings} when is_list(value) -> strings(key, value)
      {_value, type} -> {:error, "#{key} must be #{describe(type)}"}
    end
  end

  defp strings(key, values) do
    if Enum.all?(values, &is_binary/1),
      do: {:ok, values},
      else: {:error, "#{key} must be #{describe(:strings)}"}
  end

  defp describe(:string), do: "a string"
  defp describe(:integer), do: "an integer"
  defp describe(:strings), do: "a list of strings"

  # Readable markdown from stored HTML (clips, feed articles): block elements
  # become paragraphs, and links, emphasis, lists and code survive. <pre>
  # blocks are kept verbatim; all other whitespace is collapsed.
  defp html_to_markdown(html) do
    {:ok, tree} = Floki.parse_fragment(html)

    tree
    |> markdown()
    |> List.flatten()
    |> Enum.chunk_by(&is_tuple/1)
    |> Enum.map(fn
      [{:pre, _code} | _] = blocks ->
        Enum.map_join(blocks, "\n\n", fn {:pre, code} ->
          "```\n" <> String.trim_trailing(code) <> "\n```"
        end)

      text ->
        text
        |> Enum.join()
        |> String.replace(~r/[ \t]+/, " ")
        |> String.replace(~r/ ?\n ?/, "\n")
        |> String.replace(~r/\n{3,}/, "\n\n")
        |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @skipped ~w(script style noscript template svg head iframe object button form select)
  @blocks ~w(p div section article header footer main aside nav figure figcaption blockquote ul ol dl dt dd table tr address details summary)

  defp markdown(nodes) when is_list(nodes), do: Enum.map(nodes, &markdown/1)
  defp markdown(text) when is_binary(text), do: String.replace(text, ~r/\s+/, " ")
  defp markdown({tag, _attrs, _children}) when tag in @skipped, do: []
  defp markdown({"br", _attrs, _children}), do: "\n"
  defp markdown({"hr", _attrs, _children}), do: "\n\n---\n\n"
  defp markdown({"pre", _attrs, children}), do: {:pre, Floki.text(children)}
  defp markdown({"code", _attrs, children}), do: ["`", Floki.text(children), "`"]
  defp markdown({"li", _attrs, children}), do: ["\n- ", markdown(children)]
  defp markdown({tag, _attrs, children}) when tag in ~w(td th), do: [markdown(children), " | "]

  defp markdown({tag, _attrs, children}) when tag in ~w(strong b),
    do: ["**", markdown(children), "**"]

  defp markdown({tag, _attrs, children}) when tag in ~w(em i), do: ["_", markdown(children), "_"]

  defp markdown({tag, _attrs, children}) when tag in @blocks,
    do: ["\n\n", markdown(children), "\n\n"]

  defp markdown({"h" <> level, _attrs, children}) when level in ~w(1 2 3 4 5 6) do
    ["\n\n", String.duplicate("#", String.to_integer(level)), " ", markdown(children), "\n\n"]
  end

  defp markdown({"a", attrs, children}) do
    case List.keyfind(attrs, "href", 0) do
      {"href", "http" <> _ = href} -> ["[", markdown(children), "](", href, ")"]
      _ -> markdown(children)
    end
  end

  defp markdown({_tag, _attrs, children}), do: markdown(children)
  defp markdown(_comment_or_doctype), do: []
end
