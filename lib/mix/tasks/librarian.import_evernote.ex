defmodule Mix.Tasks.Librarian.ImportEvernote do
  use Mix.Task

  @shortdoc "Import notes from an Evernote ENEX export file"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {path, notebook_name} =
      case args do
        [path] ->
          {path, Path.basename(path, ".enex")}

        [path, name] ->
          {path, name}

        _ ->
          IO.puts(:stderr, "Usage: mix librarian.import_evernote <path> [notebook_name]")
          exit(:normal)
      end

    notebook_id = find_or_create_notebook(notebook_name)

    initial_state = %{
      current_note: empty_note(),
      current_resource: %{},
      in_field: nil,
      in_note_attributes: false,
      in_resource_attributes: false,
      text_buf: "",
      notes_count: 0,
      attachments_count: 0,
      errors: 0,
      notebook_id: notebook_id
    }

    stream = cdata_fixing_stream(path)

    final_state =
      case Saxy.parse_stream(stream, __MODULE__.Handler, initial_state) do
        {:ok, state} ->
          state

        {:error, reason} ->
          IO.puts(:stderr, "Parse error: #{inspect(reason)}")
          initial_state
      end

    IO.puts(
      "Imported #{final_state.notes_count} notes, #{final_state.attachments_count} attachments (#{final_state.errors} errors)"
    )
  end

  def find_or_create_notebook(name) do
    case Librarian.Vault.create_notebook(%{name: name}) do
      {:ok, nb} ->
        nb.id

      {:error, _changeset} ->
        nb = Librarian.Repo.get_by!(Librarian.Vault.Notebook, name: name)
        nb.id
    end
  end

  # Minimum lookahead needed to confirm </content> follows ]]>
  @cdata_lookahead 12

  @doc """
  Returns a Stream of fixed binary chunks — never loads the full file into memory.
  Reads in 64KB chunks, fixes ]]> inside CDATA on the fly, streams into Saxy.

  Uses a single-pass approach: when insufficient lookahead is available to
  determine if a ]]> is the real CDATA terminator, processing stops and the
  uncertain bytes are buffered for the next chunk.
  """
  def cdata_fixing_stream(file_path) do
    file_path
    |> File.stream!([], 65_536)
    |> Stream.transform(
      fn -> {false, <<>>} end,
      fn chunk, {in_cdata, buf} ->
        data = buf <> chunk
        {output, new_buf, new_in_cdata} = scan(data, [], in_cdata, false)
        {[output], {new_in_cdata, new_buf}}
      end,
      fn {in_cdata, buf} ->
        # At EOF, any remaining ]]> is the real CDATA terminator
        {output, _, _} = scan(buf, [], in_cdata, true)
        {[output], nil}
      end
    )
  end

  # Single-pass scanner. at_eof=true means don't buffer — flush everything.
  # Returns {emitted_binary, leftover_buffer, in_cdata}
  defp scan(<<>>, acc, in_cdata, _at_eof) do
    {IO.iodata_to_binary(Enum.reverse(acc)), <<>>, in_cdata}
  end

  defp scan(data, acc, in_cdata, at_eof) do
    marker = if in_cdata, do: "]]>", else: "<![CDATA["

    case :binary.match(data, marker) do
      :nomatch ->
        if in_cdata and not at_eof do
          # Keep last 2 bytes buffered in case ]]> spans the chunk boundary
          safe_len = max(0, byte_size(data) - 2)
          <<safe::binary-size(safe_len), tail::binary>> = data
          {IO.iodata_to_binary(Enum.reverse([safe | acc])), tail, true}
        else
          {IO.iodata_to_binary(Enum.reverse([data | acc])), <<>>, in_cdata}
        end

      {pos, len} ->
        <<before::binary-size(pos), _::binary-size(len), rest::binary>> = data

        if in_cdata do
          if not at_eof and byte_size(rest) < @cdata_lookahead do
            # Can't determine if this ]]> is the real terminator — buffer from here
            {IO.iodata_to_binary(Enum.reverse([before | acc])), "]]>" <> rest, true}
          else
            if String.starts_with?(String.trim_leading(rest), "</content>") do
              scan(rest, ["]]>", before | acc], false, at_eof)
            else
              scan(rest, ["]]]]><![CDATA[>", before | acc], true, at_eof)
            end
          end
        else
          scan(rest, ["<![CDATA[", before | acc], true, at_eof)
        end
    end
  end

  defmodule Handler do
    @behaviour Saxy.Handler

    @impl Saxy.Handler
    def handle_event(:start_document, _prolog, state), do: {:ok, state}

    @impl Saxy.Handler
    def handle_event(:start_element, {"note", _attrs}, state) do
      {:ok,
       %{
         state
         | current_note: Mix.Tasks.Librarian.ImportEvernote.empty_note(),
           in_field: nil,
           in_note_attributes: false,
           in_resource_attributes: false,
           text_buf: ""
       }}
    end

    def handle_event(:start_element, {"resource", _attrs}, state) do
      {:ok, %{state | current_resource: %{}, in_field: nil, text_buf: ""}}
    end

    def handle_event(:start_element, {"note-attributes", _attrs}, state) do
      {:ok, %{state | in_note_attributes: true, text_buf: ""}}
    end

    def handle_event(:start_element, {"resource-attributes", _attrs}, state) do
      {:ok, %{state | in_resource_attributes: true, text_buf: ""}}
    end

    def handle_event(:start_element, {name, _attrs}, state)
        when name in ["title", "created", "updated", "tag", "content", "guid"] do
      {:ok, %{state | in_field: name, text_buf: ""}}
    end

    def handle_event(:start_element, {"source-url", _attrs}, state) do
      if state.in_note_attributes do
        {:ok, %{state | in_field: "source-url", text_buf: ""}}
      else
        {:ok, state}
      end
    end

    def handle_event(:start_element, {"data", _attrs}, state) do
      {:ok, %{state | in_field: "data", text_buf: ""}}
    end

    def handle_event(:start_element, {"mime", _attrs}, state) do
      {:ok, %{state | in_field: "mime", text_buf: ""}}
    end

    def handle_event(:start_element, {"file-name", _attrs}, state) do
      if state.in_resource_attributes do
        {:ok, %{state | in_field: "file-name", text_buf: ""}}
      else
        {:ok, state}
      end
    end

    def handle_event(:start_element, {_name, _attrs}, state) do
      {:ok, %{state | in_field: nil}}
    end

    @impl Saxy.Handler
    def handle_event(:characters, _chars, %{in_field: nil} = state) do
      {:ok, state}
    end

    def handle_event(:characters, chars, state) do
      {:ok, %{state | text_buf: state.text_buf <> chars}}
    end

    @impl Saxy.Handler
    def handle_event(:end_element, "note-attributes", state) do
      {:ok, %{state | in_note_attributes: false, in_field: nil, text_buf: ""}}
    end

    def handle_event(:end_element, "resource-attributes", state) do
      {:ok, %{state | in_resource_attributes: false, in_field: nil, text_buf: ""}}
    end

    def handle_event(:end_element, "title", state) do
      note = %{state.current_note | title: String.trim(state.text_buf)}
      {:ok, %{state | current_note: note, in_field: nil, text_buf: ""}}
    end

    def handle_event(:end_element, "guid", state) do
      note = %{state.current_note | evernote_guid: String.trim(state.text_buf)}
      {:ok, %{state | current_note: note, in_field: nil, text_buf: ""}}
    end

    def handle_event(:end_element, "created", state) do
      note = %{
        state.current_note
        | created: Mix.Tasks.Librarian.ImportEvernote.parse_enex_date(String.trim(state.text_buf))
      }

      {:ok, %{state | current_note: note, in_field: nil, text_buf: ""}}
    end

    def handle_event(:end_element, "updated", state) do
      note = %{
        state.current_note
        | updated: Mix.Tasks.Librarian.ImportEvernote.parse_enex_date(String.trim(state.text_buf))
      }

      {:ok, %{state | current_note: note, in_field: nil, text_buf: ""}}
    end

    def handle_event(:end_element, "tag", state) do
      note = %{
        state.current_note
        | tags: state.current_note.tags ++ [String.trim(state.text_buf)]
      }

      {:ok, %{state | current_note: note, in_field: nil, text_buf: ""}}
    end

    def handle_event(:end_element, "content", state) do
      html = Mix.Tasks.Librarian.ImportEvernote.enml_to_html(state.text_buf)
      note = %{state.current_note | content: html}
      {:ok, %{state | current_note: note, in_field: nil, text_buf: ""}}
    end

    def handle_event(:end_element, "source-url", state) do
      if state.in_note_attributes do
        note = %{state.current_note | source_url: String.trim(state.text_buf)}
        {:ok, %{state | current_note: note, in_field: nil, text_buf: ""}}
      else
        {:ok, %{state | in_field: nil, text_buf: ""}}
      end
    end

    def handle_event(:end_element, "data", state) do
      resource = Map.put(state.current_resource, :data, state.text_buf)
      {:ok, %{state | current_resource: resource, in_field: nil, text_buf: ""}}
    end

    def handle_event(:end_element, "mime", state) do
      resource = Map.put(state.current_resource, :mime, String.trim(state.text_buf))
      {:ok, %{state | current_resource: resource, in_field: nil, text_buf: ""}}
    end

    def handle_event(:end_element, "file-name", state) do
      if state.in_resource_attributes do
        resource = Map.put(state.current_resource, :file_name, String.trim(state.text_buf))
        {:ok, %{state | current_resource: resource, in_field: nil, text_buf: ""}}
      else
        {:ok, %{state | in_field: nil, text_buf: ""}}
      end
    end

    def handle_event(:end_element, "resource", state) do
      note = %{
        state.current_note
        | resources: state.current_note.resources ++ [state.current_resource]
      }

      {:ok, %{state | current_note: note, current_resource: %{}, in_field: nil, text_buf: ""}}
    end

    def handle_event(:end_element, "note", state) do
      {new_count, new_attachment_count, new_errors} =
        Mix.Tasks.Librarian.ImportEvernote.save_note(
          state.current_note,
          state.notebook_id,
          state.attachments_count
        )

      total_notes = state.notes_count + new_count
      total_errors = state.errors + new_errors

      if rem(total_notes, 100) == 0 and total_notes > 0 do
        IO.puts("Progress: #{total_notes} notes imported...")
      end

      {:ok,
       %{
         state
         | current_note: Mix.Tasks.Librarian.ImportEvernote.empty_note(),
           notes_count: total_notes,
           attachments_count: new_attachment_count,
           errors: total_errors,
           in_field: nil,
           text_buf: ""
       }}
    end

    def handle_event(:end_element, _name, state) do
      {:ok, %{state | in_field: nil, text_buf: ""}}
    end

    @impl Saxy.Handler
    def handle_event(:end_document, _data, state), do: {:ok, state}
  end

  def save_note(note_data, notebook_id, current_attachment_count) do
    attrs = %{
      title: note_data.title || "Untitled",
      body: note_data.content,
      source_url: note_data.source_url,
      notebook_id: notebook_id,
      evernote_guid: note_data.evernote_guid,
      original_created_at: note_data.created
    }

    attachment_count =
      Enum.reduce(note_data.resources, current_attachment_count, fn resource, acc ->
        save_resource(resource, acc)
      end)

    case Librarian.Vault.create_note_from_import(attrs, note_data.tags) do
      {:ok, _note} ->
        {1, attachment_count, 0}

      {:error, changeset} ->
        IO.puts(:stderr, "Failed to save note '#{attrs.title}': #{inspect(changeset.errors)}")
        {0, attachment_count, 1}
    end
  end

  defp save_resource(resource, acc) do
    with data when is_binary(data) <- Map.get(resource, :data),
         decoded <- Base.decode64!(data, ignore: :whitespace),
         filename <- Map.get(resource, :file_name),
         key <- "attachments/#{:erlang.unique_integer([:positive])}_#{filename || "attachment"}",
         :ok <- Librarian.Storage.put(key, decoded) do
      acc + 1
    else
      _ -> acc
    end
  end

  def enml_to_html(enml_string) do
    case Saxy.SimpleForm.parse_string(enml_string) do
      {:ok, {"en-note", _attrs, children}} ->
        {"div", [], children}
        |> convert_node()
        |> Floki.raw_html()

      _ ->
        enml_string
    end
  end

  defp convert_node({"en-media", _attrs, _children}) do
    "[attachment]"
  end

  defp convert_node({tag, attrs, children}) do
    converted_children = Enum.map(children, &convert_node/1)
    {tag, attrs, converted_children}
  end

  defp convert_node(text) when is_binary(text), do: text

  def parse_enex_date(nil), do: nil

  def parse_enex_date(str) do
    with <<y::binary-4, m::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2,
           "Z">> <- str,
         {:ok, ndt} <-
           NaiveDateTime.new(
             String.to_integer(y),
             String.to_integer(m),
             String.to_integer(d),
             String.to_integer(h),
             String.to_integer(mi),
             String.to_integer(s)
           ) do
      DateTime.from_naive!(ndt, "Etc/UTC")
    else
      _ -> nil
    end
  end

  def empty_note do
    %{
      title: nil,
      created: nil,
      updated: nil,
      tags: [],
      content: nil,
      source_url: nil,
      evernote_guid: nil,
      resources: []
    }
  end
end
