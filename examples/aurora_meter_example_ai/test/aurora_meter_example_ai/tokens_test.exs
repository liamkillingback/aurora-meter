defmodule AuroraMeterExampleAi.TokensTest do
  @moduledoc """
  The simulated workload has to be exactly reproducible, because every
  settlement assertion in this suite names an exact figure.
  """
  use ExUnit.Case, async: true

  alias AuroraMeterExampleAi.Tokens

  doctest AuroraMeterExampleAi.Tokens

  describe "L09c-3 determinism" do
    test "the same prompt and model give the same token counts and the same bytes" do
      for prompt <- ["a", "a haiku about ledgers", String.duplicate("x", 600)],
          model <- Tokens.models() do
        assert Tokens.run(prompt, model) == Tokens.run(prompt, model)
      end
    end

    test "a different prompt gives a different completion length at least sometimes" do
      # The point of this one is that the generator VARIES. A workload that
      # returned the same completion length for every prompt would satisfy the
      # determinism test above perfectly and be measuring nothing.
      lengths =
        for n <- 1..40 do
          {_p, completion, _text} = Tokens.run("prompt number #{n}", "nimbus-1")
          completion
        end

      assert length(Enum.uniq(lengths)) > 5,
             "the completion length never varied across 40 prompts: #{inspect(Enum.uniq(lengths))}"
    end

    test "it does not disturb the caller's own :rand state" do
      :rand.seed(:exsss, {1, 2, 3})
      expected = :rand.uniform(1_000_000)

      :rand.seed(:exsss, {1, 2, 3})
      Tokens.run("something", "nimbus-1")
      assert :rand.uniform(1_000_000) == expected
    end

    test "the output says it is simulated and is built from the prompt's own words" do
      {_p, _c, text} = Tokens.run("ledgers and lanterns", "nimbus-1-mini")
      assert text =~ "simulated"
      assert text =~ "no model was called"
      assert text =~ "ledgers"
    end
  end

  describe "arithmetic" do
    test "the cost is the token count times the unit price, in integers" do
      assert Tokens.cost_micros(7, 24) == 31 * Tokens.micros_per_token()
      assert is_integer(Tokens.cost_micros(7, 24))
    end

    test "the estimate is never below the real cost, for every model" do
      for prompt <- ["a", "a slightly longer prompt", String.duplicate("y", 400)],
          model <- Tokens.models() do
        {p, c, _text} = Tokens.run(prompt, model)

        assert Tokens.estimate(prompt, model) >= Tokens.cost_micros(p, c),
               "estimate below actual for #{inspect({prompt, model})}"
      end
    end

    test "an unknown model is refused by name" do
      assert_raise ArgumentError, ~r/unknown model "gpt-nothing"/, fn ->
        Tokens.run("hello", "gpt-nothing")
      end
    end
  end

  describe "the forced failure" do
    test "a prompt beginning fail: raises" do
      assert_raise Tokens.ProviderError, fn -> Tokens.run("fail: on purpose", "nimbus-1") end
    end

    test "a prompt merely containing fail does not" do
      # Discrimination: if the check were `=~ "fail"` rather than
      # `String.starts_with?/2`, this would raise and the failure path would be
      # reachable by accident from an ordinary prompt.
      assert {_p, _c, _text} = Tokens.run("do not fail me", "nimbus-1")
    end
  end
end
