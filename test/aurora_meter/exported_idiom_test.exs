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

  ## Scope

  Two scopes, and they are enforced the same way.

    * **Every file under `lib/`**, found by wildcard rather than listed, so a
      file added tomorrow cannot escape by not being on a list. This is repair
      unit R8's half. X426 is what the shipped half of this rule is worth: the
      lot cutover gate asked the bare question, answered false on every cold
      host, and **no existing installation could move a single wallet onto
      credit lots**. Nothing saw it, because the only tests that reached the
      probe set an escape hatch and `or` short-circuits.
    * **The test files build unit 09a owns or edited**, listed in
      `@guarded_files`. That list stays a list: there are pre-existing bare call
      sites in test files 09a did not own (`oban/workers_test.exs`,
      `credits_lot_migration_test.exs`, `entitlements_test.exs`,
      `api_inventory_test.exs` and more in `optional_deps_test.exs`), and three
      deliberate ones in `credits/lot_cutover_gate_test.exs`, where asserting
      that the bare form answers false **is the test**. They are recorded in
      `docs/evidence/v1/phase-09/09a-flake.md` section 5 and in
      `open-findings.md` X435.

  ## What counts as loading it first

  `Code.ensure_loaded?(M) and function_exported?(M, f, a)`, the same module on
  both sides of one `and`. `Code.ensure_loaded!/1` and `Code.ensure_compiled!/1`
  count too, since either one raises rather than returning false.

  A guard put in a **preceding statement** does not count, because this reads
  one expression and cannot prove what a statement above it did. That shape is
  real and correct in one place, `AuroraMeter.Config.Schema.ensure_exports!/4`,
  and it is in `@allowed` by name with its reason and with a behavioural test of
  its own (`config_schema_cold_test.exs`) rather than a promise.

  ## The module may be a variable, and usually is

  09a's detector only recognised a literal alias, which is **six of this
  package's nine shipped call sites invisible**: every site that takes the module
  from configuration takes it in a variable, and a host-configured module is the
  least likely one in the system to be loaded already. The detector reads
  variables now. A module in a variable cannot be resolved statically, so it is
  reported as `{:var, :name}` and matched by that.

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
  # Everything this package ships. A wildcard, not a list: R8's sweep found that
  # a guard over a list of files is a guard over the files someone remembered.
  @lib_glob "lib/**/*.ex"

  @allowed [
    # -- shipped lib ----------------------------------------------------------
    {"lib/aurora_meter/config/schema.ex", {:var, :module},
     "`AuroraMeter.Config.Schema.ensure_exports!/4`. The statement above the check is " <>
       "`if not Code.ensure_loaded?(module), do: raise`, so the module is loaded by the time " <>
       "the check runs or the function has already stopped. The guard is a preceding " <>
       "statement rather than the same expression, which is the one shape this detector " <>
       "cannot see. Not taken on trust: `config_schema_cold_test.exs` unloads a real module " <>
       "and asks the question from a process that has never touched it, in both directions"},

    # -- test files (build unit 09a) -----------------------------------------
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

  test "I20 X426 no shipped lib file asks function_exported?/3 without loading the module first" do
    files = Path.wildcard(@lib_glob)

    assert length(files) > 50,
           "the wildcard matched #{length(files)} files, so this guard is looking at the " <>
             "wrong place and would pass over anything"

    offenders =
      for path <- files,
          {module, line} <- bare_calls(File.read!(path)),
          not allowed?(path, module),
          do: "#{path}:#{line} function_exported?(#{inspect(module)}, ...)"

    assert offenders == [],
           """
           these SHIPPED call sites ask function_exported?/3 about a module without loading it
           first:

             #{Enum.join(offenders, "\n  ")}

           `function_exported?/3` answers false for a module that has not been loaded, and in a
           host nothing has necessarily loaded any given module before this code asks. That is
           `open-findings.md` X426: the lot cutover gate asked the bare question, answered false
           on every cold host, and no installation could move a wallet onto credit lots.

           Write `Code.ensure_loaded?(M) and function_exported?(M, f, a)`. If the module really
           is provably loaded at that point, add it to @allowed with the reason, and prove the
           reason with a test that unloads the module.
           """
  end

  test "I20 the lib sweep finds a site the file list would have missed" do
    # The sweep is a wildcard because a list is a list of what someone
    # remembered. This asserts the wildcard actually reaches files nobody named:
    # @guarded_files holds two lib paths, and the package ships far more.
    listed = Enum.filter(@guarded_files, &String.starts_with?(&1, "lib/"))
    swept = Path.wildcard(@lib_glob)

    assert Enum.all?(listed, &(&1 in swept)), "the wildcard lost a file that was named"

    assert length(swept) > length(listed) + 50,
           "the wildcard is not reaching beyond the named files"
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

    # R8 changed this one. A variable module used to be ignored, which made the
    # guard blind to six of nine shipped sites. It is reported now, as a
    # variable, because it cannot be resolved any further than that.
    assert [{{:var, :m}, _}] = bare_calls(variable),
           "a bare call on a variable module is the common shape and must be seen"
  end

  test "I20 X426 the guard reads the variable forms the package actually uses" do
    # Watched failing before it was trusted passing (X350), on the exact shapes
    # in `lib/`: the safe one must be silent and the bare one must be reported,
    # with the module in a variable in both.
    wrapped_var = """
    defmodule Probe do
      def a(module, fun, arity) do
        Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
      end
    end
    """

    bang_var = """
    defmodule Probe do
      def a(module) do
        Code.ensure_loaded!(module) and function_exported?(module, :x, 1)
      end
    end
    """

    different_module = """
    defmodule Probe do
      def a(one, two) do
        Code.ensure_loaded?(one) and function_exported?(two, :x, 1)
      end
    end
    """

    preceding_statement = """
    defmodule Probe do
      def a(module) do
        if not Code.ensure_loaded?(module), do: raise("no")
        function_exported?(module, :x, 1)
      end
    end
    """

    assert bare_calls(wrapped_var) == []
    assert bare_calls(bang_var) == [], "ensure_loaded!/1 raises, so it guards just as well"

    assert [{{:var, :two}, _}] = bare_calls(different_module),
           "loading one module says nothing about another, and the guard must not confuse them"

    assert [{{:var, :module}, _}] = bare_calls(preceding_statement),
           "a guard in a preceding statement is real but unprovable from one expression, so " <>
             "it must be REPORTED and carry an @allowed entry rather than be waved through"
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

  defp exported_call({fun, meta, [subject, _f, _a]})
       when fun in [:function_exported?, :macro_exported?] do
    case module_of(subject) do
      nil -> nil
      module -> {module, meta[:line]}
    end
  end

  defp exported_call(_node), do: nil

  # `ensure_loaded!/1` and `ensure_compiled!/1` count as well: either raises
  # rather than answering false, so the call below them cannot be reached with
  # the module unloaded.
  defp ensure_loaded_of({{:., _, [{:__aliases__, _, [:Code]}, fun]}, _, [subject]})
       when fun in [:ensure_loaded?, :ensure_loaded!, :ensure_compiled!],
       do: module_of(subject)

  defp ensure_loaded_of(_node), do: nil

  # A literal alias, or a variable holding one.
  #
  # The variable clause is R8's, and it is not a refinement: six of this
  # package's nine shipped call sites pass the module in a variable, so without
  # it this guard reported on two of nine and called that a sweep.
  defp module_of({:__aliases__, _, segments}) when is_list(segments),
    do: Module.concat(segments)

  defp module_of({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: {:var, name}

  defp module_of(_node), do: nil

  defp allowed?(path, module),
    do: Enum.any?(@allowed, fn {p, m, _reason} -> p == path and m == module end)
end
