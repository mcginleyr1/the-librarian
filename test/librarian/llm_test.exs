defmodule Librarian.LLMTest do
  # async: false — the platform-key tests mutate global app env.
  use Librarian.DataCase, async: false

  alias Librarian.LLM
  alias Librarian.LLM.Usage
  alias Librarian.Settings

  @schema %{type: "object", properties: %{}, additionalProperties: false}

  defp record_spend!(cents) do
    Repo.insert!(%Usage{
      model: "claude-opus-4-8",
      purpose: "test",
      input_tokens: 1,
      output_tokens: 1,
      cost_cents: cents,
      user_id: Repo.user_id!()
    })
  end

  test "complete/3 without an API key returns :no_api_key" do
    assert {:error, :no_api_key} = LLM.complete("hi", @schema)
    refute LLM.configured?()
  end

  test "complete/3 over budget returns :budget_exceeded without calling the API" do
    {:ok, _} =
      Settings.save_settings(%{
        "anthropic_api_key" => "sk-test",
        "llm_monthly_budget_cents" => 100
      })

    record_spend!(150.0)

    assert LLM.budget_exceeded?()
    assert {:error, :budget_exceeded} = LLM.complete("hi", @schema)
  end

  test "month_spend_cents/0 only counts the current month" do
    record_spend!(50.0)
    record_spend!(25.0)

    old = record_spend!(999.0)

    last_month =
      Date.utc_today()
      |> Date.beginning_of_month()
      |> Date.add(-1)
      |> DateTime.new!(~T[12:00:00])

    Repo.update_all(
      from(u in Usage, where: u.id == ^old.id),
      set: [inserted_at: last_month]
    )

    assert LLM.month_spend_cents() == 75.0
  end

  test "budget defaults keep calls allowed until spend reaches the cap" do
    {:ok, _} =
      Settings.save_settings(%{
        "anthropic_api_key" => "sk-test",
        "llm_monthly_budget_cents" => 2000
      })

    record_spend!(1999.0)
    refute LLM.budget_exceeded?()

    record_spend!(1.0)
    assert LLM.budget_exceeded?()
  end

  describe "platform key" do
    setup do
      Application.put_env(:librarian, :platform_anthropic_api_key, "sk-platform")
      on_exit(fn -> Application.put_env(:librarian, :platform_anthropic_api_key, nil) end)
      :ok
    end

    test "serves users without their own key" do
      assert LLM.configured?()
    end

    test "is capped by the per-user allowance, not the user's own budget setting" do
      # A subscriber can't raise the platform allowance by editing their budget.
      {:ok, _} = Settings.save_settings(%{"llm_monthly_budget_cents" => 100_000})

      assert LLM.budget_cents() == LLM.platform_budget_cents()

      record_spend!(LLM.platform_budget_cents() * 1.0)
      assert LLM.budget_exceeded?()
      assert {:error, :budget_exceeded} = LLM.complete("hi", %{})
    end

    test "a user's own key restores their own budget" do
      {:ok, _} =
        Settings.save_settings(%{
          "anthropic_api_key" => "sk-own",
          "llm_monthly_budget_cents" => 5000
        })

      assert LLM.budget_cents() == 5000

      record_spend!(LLM.platform_budget_cents() * 1.0)
      refute LLM.budget_exceeded?()
    end
  end
end
