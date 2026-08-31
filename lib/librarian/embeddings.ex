defmodule Librarian.Embeddings do
  @moduledoc """
  In-BEAM text embeddings via Bumblebee, served through a supervised `Nx.Serving`.

  Uses `sentence-transformers/all-MiniLM-L6-v2` (384 dimensions, L2-normalized) on
  the EXLA CPU backend. No external server — embeddings power semantic search,
  "more like this", and the personalized stream's ranking prefilter.

  The serving is added to the supervision tree by `Librarian.Application` when
  `:start_embedding_serving` is true (disabled in tests).
  """

  @serving __MODULE__.Serving
  @dimensions 384
  @max_chars 8_000

  def dimensions, do: @dimensions

  @doc """
  Character cap applied to text before embedding. Callers that read wide,
  TOASTed columns should truncate in SQL to this (`left(col, ?)`) so Postgres
  never de-TOASTs a whole multi-MB body just to embed its first #{@max_chars}
  chars — the model's 512-token window only ever sees the leading prefix anyway.
  """
  def max_chars, do: @max_chars

  @doc "Child spec that loads the model and builds the embedding serving."
  def child_spec(_opts) do
    repo = Application.fetch_env!(:librarian, :embedding_model)
    {:ok, model_info} = Bumblebee.load_model({:hf, repo})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, repo})

    serving =
      Bumblebee.Text.text_embedding(model_info, tokenizer,
        compile: [batch_size: 16, sequence_length: 512],
        defn_options: [compiler: EXLA],
        output_attribute: :hidden_state,
        output_pool: :mean_pooling,
        embedding_processor: :l2_norm
      )

    {Nx.Serving, serving: serving, name: @serving, batch_timeout: 100}
  end

  @doc """
  Embeds a single piece of text, returning `{:ok, %Pgvector{}}` or `{:error, reason}`.
  """
  def embed(text) when is_binary(text) do
    %{embedding: tensor} = Nx.Serving.batched_run(@serving, truncate(text))
    {:ok, tensor |> Nx.to_flat_list() |> Pgvector.new()}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def embed(nil), do: {:error, :no_text}

  defp truncate(text), do: String.slice(text, 0, @max_chars)
end
