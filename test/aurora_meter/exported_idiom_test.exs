defmodule AuroraMeter.ExportedIdiomTest do
  @moduledoc """
  Build unit 09a. `function_exported?/3` is never asked about an optional module
  without loading it first.

  ## Why this file exists

  `function_exported?/3` answers **false for a function that exists** when its
  module has not been loaded, and the BEAM loads modules on demand. So the bare
  call asks "did something already call into this module in this run", which is a
  question about the seed and the run set rather than about the code.

  Build unit 09a introduced the first module in this package that is **always
  compiled** and puts only some of its functions behind an optional-dependency
  guard (`AuroraMeter.LiveView`), and then asked about those functions with the
  bare form in four places. Two independent repair units saw the resulting flake
  before this test existed: about one run in three, and 5 of 5 when the owning
  test was run on its own.

  The package already knew. `lib/aurora_meter/oban.ex`,
  `lib/aurora_meter/exporter_case.ex`, `lib/aurora_meter/period.ex`,
  `lib/aurora_meter/plans.ex` and `lib/aurora_meter/subscriptions/preview.ex` all
  use `Code.ensure_loaded?(m) and function_exported?(m, f, a)`, and
  `optional_deps_test.exs` has carried a comment explaining it since build unit
  03b. **A rule that only lives in a comment is a rule already being broken**
  (`open-findings.md` X153), and this one was.

  ## Scope, deliberately narrow

  This guard covers the files build unit 09a owns or edited, listed in
  `@guarded_files`. It is **not** tree-wide, and that is a decision rather than
  an oversight: there are pre-existing bare call sites in files this unit does
  not own (`oban/workers_test.exs`, `credits_lot_migration_test.exs`,
  `entitlements_test.exs` and four more in `optional_deps_test.exs` that predate
  09a), and a guard that failed their build would be this unit changing another
  unit's work by proxy. They are recorded in
  `docs/evidence/v1/phase-09/09a-flake.md` section 5 for whoever owns them.

  It reads the AST rather than grepping, because a comment mentioning
  `function_exported?/3` is not a call to it, and half the call sites in this
  package sit next to a comment about exactly this.
  """
  use ExUnit.Case, async: true

  # The files 09a wrote or edited. A bare `function_exported?/3` on a literal
  # module alias in one of these is a failure.
  @guarded_files [
    "test/aurora_meter/optional_deps_test.exs",
    "test/aurora_meter/doc_examples_test.exs",
    "test/aurora_meter/live_view_test.exs",
    "test/aurora_meter/plug/ensure_entitled_test.exs",
    "test/aurora_meter/realtime_test.exs",
    "lib/aurora_meter/live_view.ex",
    "lib/aurora_meter/plug/ensure_entitled.ex"
  ]

  # Call sites in the guarded files that predate 09a and are safe for a reason
  # written here. An entry that no longer matches anything fails the test below,
  # so the list cannot outlive what it excuses.
  # The module is written as it appears in the SOURCE, not as it resolves: this
  # guard reads the AST and cannot follow an `alias`, so `Credits` here is the
  # bare alias `optional_deps_test.exs` writes, not `AuroraMeter.Credits`. That
  # limitation is deliberate and is the reason the guard only ever reports a
  # literal alias; a module in a variable is uncheckable statically and is
  # ignored.
  @allowed [
    {"test/aurora_meter/optional_deps_test.exs", Mix.Tasks.AuroraMeter.Install,
     "build unit 03b's own case, and the one that documented this trap for the package. " <>
       "It carries `assert Code.ensure_loaded?(Mix.Tasks.AuroraMeter.Install)` on the line " <>
       "above, with the measurement that explains why. Safe by adjacency, which is the " <>
       "fragile form, but it is not 09a's to change"},
    {"test/aurora_meter/optional_deps_test.exs", AuroraMeter.OpenTelemetry,
     "build unit 08b's, with `assert Code.ensure_loaded?(AuroraMeter.OpenTelemetry)` " <>
       "immediately above it; not 09a's to change"},
    {"test/aurora_meter/optional_deps_test.exs", Credits,
     "build unit 05a's, inside a test whose earlier lines call into the module; not 09a's " <>
       "to change"}
  ]

  test "I20 no guarded file asks function_exported?/3 without loading the module first" do
    offenders =
      for path <- @guarded_files,
          File.exists?(path),
          {module, line} <- bare_calls(File.read!(path)),
          not allowed?(path, module),
          do: "#{path}:#{line} function_exported?(#{inspect(module)}, ...)"

    assert offenders == [],
           """
           these ask function_exported?/3 about a literal module without loading it first:

             #{Enum.join(offenders, "\n  ")}

           `function_exported?/3` answers false for a module that has not been loaded, so
           the bare form depends on whether some earlier test happened to call into it.
           Use the local `exported?/3` helper, or write
           `Code.ensure_loaded?(M) and function_exported?(M, f, a)`.
           """
  end

  test "I20 every allow-list entry still matches a real call site" do
    # An exemption that no longer applies is an exemption that will one day
    # excuse something else.
    stale =
      for {path, module, _reason} <- @allowed,
          not Enum.any?(bare_calls(File.read!(path)), fn {m, _line} -> m == module end),
          do: "#{path} no longer has a bare call on #{inspect(module)}"

    assert stale == [],
           "stale allow-list entries, delete them:\n  " <> Enum.join(stale, "\n  ")
  end

  test "I20 the guard sees a bare call, and does not see a wrapped one" do
    # The detector watched failing before it is trusted passing (X350). Both
    # halves: it must FIND the bare form and must NOT report the safe one.
    bare = """
    defmodule Probe do
      def a, do: function_exported?(AuroraMeter.LiveView, :switch_tenant, 2)
    end
    """

    wrapped = """
    defmodule Probe do
      def a do
        Code.ensure_loaded?(AuroraMeter.LiveView) and
          function_exported?(AuroraMeter.LiveView, :switch_tenant, 2)
      end
    end
    """

    commented = """
    defmodule Probe do
      # function_exported?(AuroraMeter.LiveView, :switch_tenant, 2) is wrong here
      def a, do: :ok
    end
    """

    variable = """
    defmodule Probe do
      def a(m), do: function_exported?(m, :x, 1)
    end
    """

    assert [{AuroraMeter.LiveView, _}] = bare_calls(bare)
    assert bare_calls(wrapped) == []
    assert bare_calls(commented) == [], "a comment is not a call; this guard reads the AST"
    assert bare_calls(variable) == [], "a variable module cannot be checked statically"
  end

  # Every `function_exported?/3` (or `macro_exported?/3`) whose first argument is
  # a literal module alias and which is NOT the right-hand side of an `and` whose
  # left-hand side is `Code.ensure_loaded?/1` of the same module.
  defp bare_calls(source) do
    {:ok, tree} = Code.string_to_quoted(source)

    {_tree, {_safe, found}} =
      Macro.prewalk(tree, {MapSet.new(), []}, fn node, acc ->
        {node, visit(node, acc)}
      end)

    Enum.reverse(found)
  end

  # The idiom itself: `Code.ensure_loaded?(M) and function_exported?(M, f, a)`,
  # the SAME module on both sides. Remember the right-hand node so the walk does
  # not report it when it reaches it on its own.
  defp visit({:and, _, [left, right]}, {safe, found}) do
    case {ensure_loaded_of(left), exported_call(right)} do
      {module, {module, _line}} when not is_nil(module) ->
        {MapSet.put(safe, node_key(right)), found}

      _other ->
        {safe, found}
    end
  end

  defp visit(node, acc), do: record(node, exported_call(node), acc)

  defp record(_node, nil, acc), do: acc

  defp record(node, {module, line}, {safe, found}) do
    if MapSet.member?(safe, node_key(node)),
      do: {safe, found},
      else: {safe, [{module, line} | found]}
  end

  defp node_key({_fun, meta, args}), do: {meta[:line], length(args)}

  defp exported_call({fun, meta, [{:__aliases__, _, segments}, _f, _a]})
       when fun in [:function_exported?, :macro_exported?] and is_list(segments) do
    {Module.concat(segments), meta[:line]}
  end

  defp exported_call(_node), do: nil

  defp ensure_loaded_of(
         {{:., _, [{:__aliases__, _, [:Code]}, :ensure_loaded?]}, _,
          [{:__aliases__, _, segments}]}
       )
       when is_list(segments),
       do: Module.concat(segments)

  defp ensure_loaded_of(_node), do: nil

  defp allowed?(path, module),
    do: Enum.any?(@allowed, fn {p, m, _reason} -> p == path and m == module end)
end
