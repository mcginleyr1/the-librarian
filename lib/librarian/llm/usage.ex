defmodule Librarian.LLM.Usage do
  use Ecto.Schema

  schema "llm_usage" do
    field :model, :string
    field :purpose, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cost_cents, :float

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
