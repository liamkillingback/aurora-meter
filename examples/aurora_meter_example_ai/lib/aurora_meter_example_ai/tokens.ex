defmodule AuroraMeterExampleAi.Tokens do
  @moduledoc """
  The simulated workload. **There is no AI in this application.**

  No account, no key, no HTTP client, no network call of any kind. This module
  computes a token count and assembles a paragraph out of the words of the
  prompt it was given, and it does it the same way every time for the same
  input. That is the whole of it, and it is deliberate: the sample exists to
  show how metering, quotas and credits fit around a unit of work, and a real
  provider would make the sample unrunnable for anyone without an account and
  unpredictable for the tests.

  The output is assembled from the prompt's own words precisely so that it can
  never be mistaken for a model's answer.

  ## Determinism

  `run/2` seeds a **local** generator from `:erlang.phash2({prompt, model})` and
  threads its state, so it never touches the calling process's `:rand` seed.
  Identical input gives an identical token count and identical bytes, which is
  what lets the suite assert an exact settlement figure rather than a range.

  ## Prices

  One token costs #{10} micro-dollars, so ten thousand tokens is ten cents.
  The figure lives here, next to the thing that produces the tokens, because a
  cost per unit that lives somewhere else is a cost per unit that drifts.

  ## Forcing a failure

  A prompt beginning `fail:` raises `AuroraMeterExampleAi.Tokens.ProviderError`.
  It is how the sample's failure path is reached from a browser without a
  debugger: the reservation is released, the hold is released, and nothing is
  billed. See `AuroraMeterExampleAi.Generations`.
  """

  defmodule ProviderError do
    @moduledoc "Raised by the simulated workload when a prompt asks it to fail."
    defexception [:message]
  end

  @micros_per_token 10

  # {completion_floor, completion_spread}: the range the simulated completion
  # length is drawn from, per model. Both models exist so the sample has a
  # dimension worth breaking usage down by on the `/ops` page.
  @models %{
    "nimbus-1" => {24, 96},
    "nimbus-1-mini" => {8, 32}
  }

  @doc "The models this sample pretends to have."
  @spec models() :: [String.t()]
  def models, do: @models |> Map.keys() |> Enum.sort()

  @doc "Micro-dollars per token."
  @spec micros_per_token() :: pos_integer()
  def micros_per_token, do: @micros_per_token

  @doc """
  What a generation is expected to cost, in micro-dollars, before it runs.

  This is the amount held. It is an estimate on purpose and it is deliberately
  generous: the hold is what stops two concurrent generations spending the same
  credit, and an estimate below the real cost would let a wallet go further
  than it can afford. The difference between this and the actual is settled,
  not charged twice.

  ## Examples

      iex> AuroraMeterExampleAi.Tokens.estimate("hello", "nimbus-1-mini")
      420

  """
  @spec estimate(String.t(), String.t()) :: pos_integer()
  def estimate(prompt, model) when is_binary(prompt) and is_binary(model) do
    {floor, spread} = model!(model)
    max(prompt_tokens(prompt) + floor + spread, 1) * @micros_per_token
  end

  @doc """
  Runs the simulated work.

  Returns `{prompt_tokens, completion_tokens, output}`. Raises
  `AuroraMeterExampleAi.Tokens.ProviderError` for a prompt beginning `fail:`.

  ## Examples

      iex> AuroraMeterExampleAi.Tokens.run("ledgers", "nimbus-1-mini") ==
      ...>   AuroraMeterExampleAi.Tokens.run("ledgers", "nimbus-1-mini")
      true

  """
  @spec run(String.t(), String.t()) :: {pos_integer(), pos_integer(), String.t()}
  def run(prompt, model) when is_binary(prompt) and is_binary(model) do
    {floor, spread} = model!(model)

    if String.starts_with?(prompt, "fail:") do
      raise ProviderError, message: "the simulated provider refused: " <> prompt
    end

    seed = :erlang.phash2({prompt, model})
    state = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
    {draw, _state} = :rand.uniform_s(spread, state)

    completion = floor + draw - 1
    sleep_for(completion)

    {prompt_tokens(prompt), completion, output(prompt, model, completion)}
  end

  @doc """
  The cost in micro-dollars of a completed generation.

  ## Examples

      iex> AuroraMeterExampleAi.Tokens.cost_micros(10, 30)
      400

  """
  @spec cost_micros(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def cost_micros(prompt_tokens, completion_tokens)
      when is_integer(prompt_tokens) and is_integer(completion_tokens) do
    (prompt_tokens + completion_tokens) * @micros_per_token
  end

  @doc """
  The rough token count of a string: four bytes to a token, rounded up.

  Computed rather than sampled, so it is exactly reproducible.

  ## Examples

      iex> AuroraMeterExampleAi.Tokens.prompt_tokens("12345")
      2

  """
  @spec prompt_tokens(String.t()) :: pos_integer()
  def prompt_tokens(prompt) when is_binary(prompt) do
    max(ceil(byte_size(prompt) / 4), 1)
  end

  @spec model!(String.t()) :: {pos_integer(), pos_integer()}
  defp model!(model) do
    case Map.fetch(@models, model) do
      {:ok, range} ->
        range

      :error ->
        raise ArgumentError,
              "unknown model #{inspect(model)}, expected one of #{inspect(models())}"
    end
  end

  # A visible pause so that a human clicking "generate" sees the meter move
  # rather than finding it already moved. Zero in the test environment, which is
  # the only reason the suite is not slowed by simulated work.
  @spec sleep_for(pos_integer()) :: :ok
  defp sleep_for(completion_tokens) do
    per_token = Application.get_env(:aurora_meter_example_ai, :workload_micros_per_token, 0)

    case div(completion_tokens * per_token, 1000) do
      0 -> :ok
      ms -> Process.sleep(ms)
    end
  end

  @spec output(String.t(), String.t(), pos_integer()) :: String.t()
  defp output(prompt, model, completion_tokens) do
    words =
      prompt
      |> String.split(~r/\W+/, trim: true)
      |> Enum.reject(&(&1 == ""))
      |> case do
        [] -> ["nothing"]
        list -> list
      end

    body =
      words
      |> Stream.cycle()
      |> Enum.take(completion_tokens)
      |> Enum.join(" ")

    "[simulated #{model} output, #{completion_tokens} tokens, no model was called] " <> body
  end
end
