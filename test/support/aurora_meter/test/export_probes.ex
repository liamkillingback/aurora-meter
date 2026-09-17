defmodule AuroraMeter.Test.ExportProbes do
  @moduledoc """
  Two modules for asking `function_exported?/3` questions **cold** (repair unit
  R8, `open-findings.md` X426).

  They live here rather than inside the test file that uses them, and that is
  the whole point. A module defined inside an `.exs` test file is compiled into
  memory and has no `.beam` on the code path, so `:code.purge/1` removes it for
  good and `Code.ensure_loaded?/1` then answers `false` with `:nofile`. A cold
  test built on one of those proves the opposite of what it claims: the check
  under test refuses the module because it genuinely cannot be loaded, not
  because it was asked before the load. `test/support` is on
  `elixirc_paths(:test)`, so these two are real compiled modules that can be
  unloaded and loaded again, which is what makes the question askable twice.

  `Complete` exports the probe contract. `Partial` deliberately does not.
  """

  defmodule Complete do
    @moduledoc "Exports the probe contract: `ping/0` and `describe/1`."

    @doc "Answers `:pong`."
    def ping, do: :pong

    @doc "Answers `:ok` for any argument."
    def describe(_arg), do: :ok
  end

  defmodule Partial do
    @moduledoc "Exports half the probe contract, so a contract check must refuse it."

    @doc "Answers `:pong`."
    def ping, do: :pong
  end
end
