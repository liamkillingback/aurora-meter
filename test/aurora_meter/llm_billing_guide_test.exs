defmodule AuroraMeter.LlmBillingGuideTest do
  @moduledoc """
  Runs the code in `docs/llm-billing-with-req-llm.md` against the real credit
  ledger.

  The guide's two modules are read out of the markdown, renamed from `MyApp.*`
  to a namespace of this test's own, and compiled, so the published sample and
  this test cannot drift. ReqLLM is not a dependency of this package, so a stub
  with the shape ReqLLM 1.29 documents stands in for it: `generate_text/3`
  answers `{:ok, response}` or `{:error, reason}`, and `ReqLLM.Response.usage/1`
  answers a map of token counts (or `nil`).
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Credits

  @guide "docs/llm-billing-with-req-llm.md"

  defmodule Stub do
    @moduledoc false
    def set(result), do: Process.put({__MODULE__, :result}, result)
    def calls, do: Process.get({__MODULE__, :calls}, 0)

    def call do
      Process.put({__MODULE__, :calls}, calls() + 1)
      Process.get({__MODULE__, :result})
    end
  end

  setup_all do
    unless Code.ensure_loaded?(ReqLLM) do
      Code.compile_string("""
      defmodule ReqLLM do
        def generate_text(_model, _prompt, _opts), do: AuroraMeter.LlmBillingGuideTest.Stub.call()
      end

      defmodule ReqLLM.Response do
        def text(%{text: text}), do: text
        def usage(%{usage: usage}), do: usage
      end
      """)
    end

    blocks =
      ~r/```elixir\n(defmodule MyApp\.(?:AIPricing|AI) do.*?)```/s
      |> Regex.scan(File.read!(@guide), capture: :all_but_first)
      |> Enum.map(fn [code] -> String.replace(code, "MyApp.", "LlmGuide.") end)

    assert length(blocks) == 2, "the guide's two modules were not found in #{@guide}"
    Enum.each(blocks, &Code.compile_string/1)
    :ok
  end

  setup do
    org = unique_tenant("llm")
    {:ok, _} = Credits.grant(org, 1_000_000, reference: "llm-grant-#{org}")
    %{org: org}
  end

  test "a call is held, made and settled from the reported token usage", %{org: org} do
    Stub.set({:ok, %{text: "hello", usage: %{input_tokens: 100, output_tokens: 200}}})

    assert {:ok, "hello"} = LlmGuide.AI.complete(org, "Say hello", "req-1")

    # 100 x 3 + 200 x 15 micro-dollars, and the hold is gone.
    balance = Credits.balance(org)
    assert balance.balance == 1_000_000 - (100 * 3 + 200 * 15)
    assert balance.held == 0
    assert Stub.calls() == 1
  end

  test "a missing usage map charges the estimate rather than nothing", %{org: org} do
    Stub.set({:ok, %{text: "hello", usage: nil}})

    assert {:ok, "hello"} = LlmGuide.AI.complete(org, "Say hello", "req-2")

    estimate = LlmGuide.AIPricing.estimate("Say hello", 1_024)
    assert Credits.balance(org).balance == 1_000_000 - estimate
  end

  test "a tenant without the estimate available is refused and the model is not called" do
    broke = unique_tenant("llm_broke")
    Stub.set({:ok, %{text: "never", usage: %{input_tokens: 1, output_tokens: 1}}})

    assert {:error, :insufficient_credits} = LlmGuide.AI.complete(broke, "Say hello", "req-3")
    assert Stub.calls() == 0
  end

  test "a failed call releases the hold and charges nothing", %{org: org} do
    Stub.set({:error, :timeout})

    assert {:error, :timeout} = LlmGuide.AI.complete(org, "Say hello", "req-4")

    balance = Credits.balance(org)
    assert balance.balance == 1_000_000
    assert balance.held == 0
  end

  test "a retry with the same request id is refused rather than charged twice", %{org: org} do
    Stub.set({:ok, %{text: "hello", usage: %{input_tokens: 10, output_tokens: 10}}})

    assert {:ok, "hello"} = LlmGuide.AI.complete(org, "Say hello", "req-5")
    assert {:error, :duplicate_reference} = LlmGuide.AI.complete(org, "Say hello", "req-5")
    assert Credits.balance(org).balance == 1_000_000 - (10 * 3 + 10 * 15)
  end
end
