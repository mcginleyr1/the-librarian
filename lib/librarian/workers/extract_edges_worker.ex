defmodule Librarian.Workers.ExtractEdgesWorker do
  @moduledoc """
  Types the relationships between one note and its pgvector neighbors via
  Claude structured outputs. The LLM only ranks/types candidates similarity
  already surfaced — never O(n²) comparisons. Marks the note indexed even
  when zero edges come back, so budget isn't burned re-asking.
  """
  use Oban.Worker,
    queue: :vault,
    max_attempts: 3,
    unique: [keys: [:note_id], period: 300]

  require Logger

  alias Librarian.{LLM, Repo, Vault}

  @candidates 10
  @body_chars 3000
  @excerpt_chars 500
  @edge_kinds ~w(extends contradicts example_of references same_topic)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"note_id" => note_id}}) do
    case Repo.get(Librarian.Vault.Note, note_id, skip_tenant: true) do
      nil ->
        {:cancel, :note_deleted}

      %{embedding: nil} ->
        {:cancel, :not_embedded}

      note ->
        Repo.with_user(note.user_id, fn -> extract(Vault.get_note!(note_id)) end)
    end
  end

  defp extract(note) do
    candidates = Vault.neighbor_candidates(note, @candidates)

    case candidates do
      [] ->
        mark_indexed(note)
        :ok

      candidates ->
        case LLM.complete(prompt(note, candidates), schema(), purpose: "edge_extraction") do
          {:ok, %{"edges" => edges}} ->
            store_edges(note, edges, candidates)
            mark_indexed(note)
            :ok

          {:error, reason} when reason in [:no_api_key, :budget_exceeded] ->
            {:cancel, reason}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp store_edges(note, edges, candidates) do
    candidate_ids = MapSet.new(candidates, & &1.id)

    entries =
      edges
      |> Enum.filter(fn e ->
        is_integer(e["target_id"]) and MapSet.member?(candidate_ids, e["target_id"]) and
          e["kind"] in @edge_kinds
      end)
      |> Enum.map(fn e ->
        %{
          source_note_id: note.id,
          target_note_id: e["target_id"],
          kind: e["kind"],
          reason: e["reason"],
          weight: clamp(e["weight"]),
          origin: "llm"
        }
      end)

    {count, _} = Vault.upsert_edges(entries)
    Logger.info("ExtractEdgesWorker: note #{note.id} -> #{count} typed edges")
  end

  defp mark_indexed(note) do
    note
    |> Ecto.Changeset.change(graph_indexed_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  defp clamp(w) when is_number(w), do: w |> max(0.0) |> min(1.0) |> :erlang.float()
  defp clamp(_), do: 0.5

  defp prompt(note, candidates) do
    annotations = Vault.list_annotations(note.id)

    annotation_block =
      case annotations do
        [] -> ""
        list -> "\nMy annotations on this note:\n" <> Enum.map_join(list, "\n", &"- #{&1.body}")
      end

    candidate_block =
      Enum.map_join(candidates, "\n\n", fn c ->
        "[id #{c.id}] #{c.title}\n#{truncate(c.body, @excerpt_chars)}"
      end)

    """
    You are organizing a personal knowledge vault into a knowledge graph.

    SOURCE NOTE [id #{note.id}]
    Title: #{note.title}
    Tags: #{Enum.map_join(note.tags, ", ", & &1.name)}
    Body:
    #{truncate(note.body, @body_chars)}
    #{annotation_block}

    CANDIDATE NOTES (pre-filtered by embedding similarity):

    #{candidate_block}

    For each candidate genuinely related to the source note, emit one edge.
    Direction reads "source KIND target": the source note extends / contradicts /
    is an example_of / references / shares the same_topic as the target.
    reason: one specific sentence explaining the connection — it will be shown
    to the vault's owner while browsing.
    weight: your confidence from 0.0 to 1.0.

    Only emit edges worth showing to a person curating their own knowledge.
    Skip weak, generic, or merely-same-genre connections. Zero edges is a
    perfectly good answer.
    """
  end

  defp truncate(nil, _max), do: ""

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp schema do
    %{
      type: "object",
      properties: %{
        edges: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              target_id: %{type: "integer"},
              kind: %{type: "string", enum: @edge_kinds},
              reason: %{type: "string"},
              weight: %{type: "number"}
            },
            required: ["target_id", "kind", "reason", "weight"],
            additionalProperties: false
          }
        }
      },
      required: ["edges"],
      additionalProperties: false
    }
  end
end
