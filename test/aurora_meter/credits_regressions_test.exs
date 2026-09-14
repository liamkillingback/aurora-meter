defmodule AuroraMeter.CreditsRegressionsTest do
  @moduledoc """
  Replays every saved history in `test/regressions/seeds/` against the real
  database, deterministically and with StreamData out of the picture (build
  unit 01e).

  Each file is both a test input and a piece of evidence. Two kinds live there:

    * a **counterexample** the property found, shrunk by StreamData to its
      smallest failing form and written by
      `AuroraMeter.Test.LedgerCommands.save_seed/1`;
    * a **hand-written fixture** recording a behaviour the ledger has today that
      a later unit changes, so the change has a before and an after rather than
      a recollection.

  A file whose `:expect` is `:agreement` must replay to the exact state it
  records. One whose `:expect` is `{:disagreement, unit}` is a defect that is
  still open: the replay is asserted to **fail**, and it stays here until `unit`
  lands and flips it. Deleting a seed file to make the suite green is never the
  fix.

  The directory is read at load time, so a file added since the last run gets
  its own test on the next one. `test every saved seed file parses and names an
  invariant` validates the shape of every file, so a malformed one fails this
  module loudly instead of being quietly skipped.
  """
  use ExUnit.Case, async: false

  alias AuroraMeter.Config
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.LedgerCommands
  alias AuroraMeter.Test.LedgerModel

  @seed_glob "test/regressions/seeds/*.exs"
  @seeds @seed_glob |> Path.wildcard() |> Enum.sort()

  @kinds [:grant, :hold, :settle, :release, :debit, :reverse, :expire_due]

  setup_all do
    Connections.checkout!()
    before = Connections.row_counts()

    on_exit(fn ->
      Connections.checkout!()
      remaining = Connections.row_counts()

      if remaining != before do
        raise "#{inspect(__MODULE__)} left rows behind: #{inspect(before)} -> #{inspect(remaining)}"
      end
    end)

    :ok
  end

  setup do
    Connections.checkout!()
    :ok
  end

  test "every saved seed file parses and names an invariant" do
    found = Path.wildcard(@seed_glob)

    assert Enum.sort(found) == @seeds,
           "the seed directory changed after this module was loaded; run `mix test` again so " <>
             "each new file gets its own replay: #{inspect(Enum.sort(found) -- @seeds)}"

    for path <- found do
      seed = load!(path)

      assert Regex.match?(~r/^I\d\d$/, seed.invariant), "#{path}: :invariant must be I<nn>"

      assert String.starts_with?(seed.name, "seed for #{seed.invariant}: "),
             "#{path}: :name must start with \"seed for #{seed.invariant}: \""

      assert is_list(seed.history) and seed.history != [], "#{path}: :history must be non-empty"
      assert is_map(seed.expected), "#{path}: :expected must be the final projections"
      assert is_integer(seed.tolerance), "#{path}: :tolerance must be an integer"
      assert match?(%DateTime{}, seed.base_instant), "#{path}: :base_instant must be a DateTime"

      assert seed.expect == :agreement or
               match?({:disagreement, unit} when is_binary(unit), seed.expect),
             "#{path}: :expect must be :agreement or {:disagreement, \"<unit>\"}"

      for command <- seed.history do
        assert elem(command, 0) in @kinds, "#{path}: unknown command #{inspect(command)}"
      end
    end
  end

  for path <- @seeds do
    @path path

    test "replays #{Path.basename(path)}" do
      replay!(@path)
    end
  end

  # -- replay -----------------------------------------------------------------

  defp replay!(path) do
    seed = load!(path)

    assert seed.tolerance == Config.credits_overdraft_tolerance(),
           "#{path} was recorded at an overdraft tolerance of #{seed.tolerance} and this run " <>
             "is configured for #{Config.credits_overdraft_tolerance()}; the histories are not " <>
             "comparable. Set :credits_overdraft_tolerance back, or re-record the seed."

    opts = [seed: seed.seed, label: Path.basename(path), save: false]

    case seed.expect do
      :agreement ->
        result = LedgerCommands.run(seed.history, opts)

        assert LedgerModel.projections(result.model) == seed.expected,
               "#{path}: the saved history no longer produces the state the file records. " <>
                 "Either the ledger changed or the file was edited; do not update the file " <>
                 "without saying which."

      {:disagreement, unit} ->
        assert_raise ExUnit.AssertionError, fn -> LedgerCommands.run(seed.history, opts) end

        # The file stays until `unit` lands. When it does, that unit flips
        # `:expect` to `:agreement` in the same change that fixes `lib/`.
        assert is_binary(unit)
    end
  end

  defp load!(path) do
    {term, _bindings} = Code.eval_file(path)
    term
  rescue
    error ->
      flunk("#{path} does not parse as a seed file: #{Exception.message(error)}")
  end
end
