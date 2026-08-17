defmodule Librarian.LLM do
  @moduledoc """
  Minimal Anthropic Messages API client. The API key and a monthly budget
  live in Settings; every call is gated on month-to-date spend and recorded
  in llm_usage, so a runaway job stops at the budget instead of the bill.
  """

  import Ecto.Query
  alias Librarian.LLM.Usage
  alias Librarian.{Repo, Settings}

  @endpoint "https://api.anthropic.com/v1/messages"
  @model "claude-opus-4-8"
  # USD per million tokens
  @input_price 5.0
  @output_price 25.0

  def model, do: @model

  def month_spend_cents do
    start =
      Date.utc_today() |> Date.beginning_of_month() |> DateTime.new!(~T[00:00:00])

    Repo.one(
      from u in Usage,
        where: u.inserted_at >= ^start,
        select: coalesce(sum(u.cost_cents), 0.0)
    )
  end

  def budget_exceeded? do
    month_spend_cents() >= Settings.llm_monthly_budget_cents()
  end

  def configured? do
    match?({:ok, _}, api_key())
  end

  @doc """
  One completion constrained to `schema` (JSON Schema, structured outputs).
  Returns {:ok, decoded_map} or {:error, :no_api_key | :budget_exceeded | term}.
  """
  def complete(prompt, schema, opts \\ []) do
    purpose = Keyword.get(opts, :purpose, "general")
    max_tokens = Keyword.get(opts, :max_tokens, 16_000)

    with {:ok, key} <- api_key(),
         :ok <- check_budget() do
      request(key, prompt, schema, max_tokens, purpose)
    end
  end

  defp api_key do
    case Settings.get_settings() do
      %{anthropic_api_key: key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :no_api_key}
    end
  end

  defp check_budget do
    if budget_exceeded?(), do: {:error, :budget_exceeded}, else: :ok
  end

  defp request(key, prompt, schema, max_tokens, purpose) do
    body = %{
      model: @model,
      max_tokens: max_tokens,
      thinking: %{type: "adaptive"},
      output_config: %{format: %{type: "json_schema", schema: schema}},
      messages: [%{role: "user", content: prompt}]
    }

    case Req.post(@endpoint,
           json: body,
           headers: [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}],
           receive_timeout: 300_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"content" => content, "usage" => usage} = resp}} ->
        record_usage(usage, purpose)
        parse_response(resp["stop_reason"], content)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response("refusal", _content), do: {:error, :refusal}

  defp parse_response(_stop_reason, content) do
    with %{"text" => text} <- Enum.find(content, &(&1["type"] == "text")),
         {:ok, decoded} <- Jason.decode(text) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp record_usage(%{"input_tokens" => input, "output_tokens" => output}, purpose) do
    cost_cents =
      input / 1_000_000 * @input_price * 100 + output / 1_000_000 * @output_price * 100

    Repo.insert!(%Usage{
      model: @model,
      purpose: purpose,
      input_tokens: input,
      output_tokens: output,
      cost_cents: cost_cents,
      user_id: Repo.user_id!()
    })
  end

  defp record_usage(_usage, _purpose), do: :ok
end
