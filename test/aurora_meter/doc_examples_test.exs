defmodule AuroraMeter.DocExamplesTest do
  @moduledoc """
  Keeps the Elixir in Aurora Meter's published guides honest.

  A port of `AuroraMeter.Pro.DocExamplesTest`, keeping its four layers and its
  reasoning, because core had no doc-example harness at all
  (`open-findings.md` X184) and the failure it exists to prevent is the one P13
  recorded in Pro: a guide that names a function the package stopped exporting,
  found by a customer rather than by the build.

  Four layers, weakest to strongest.

    1. **Every `elixir` block parses.** A block that does not is not Elixir, and
       a fence that says it is, is wrong.
    2. **Every `AuroraMeter*` module a block names exists.**
    3. **Every `AuroraMeter*.function(` a block calls is exported at some
       arity.** The arity is deliberately not checked: a doc snippet pipes and
       wraps lines, so counting arguments from text invents failures. What this
       catches is the failure that actually happens, which is a renamed or
       deleted function.
    4. **Every block whose top level is nothing but `defmodule` declarations is
       compiled for real**, at top level so its bodies are compiled rather than
       quoted.

  ### Why not "compile every block", which 02a's build document specifies

  Most blocks in these guides are fragments: a bare `config :aurora_meter, ...`
  call, a crontab tuple, a `def deps do ... end` without its module. Wrapping a
  fragment in a synthetic module and compiling it fails on `config/2` being
  undefined, which says nothing about the guide and everything about the
  wrapper. Layers 2 and 3 catch what compiling was meant to catch (a name that
  no longer exists) across **all** the blocks rather than the handful that
  happen to be self-contained.

  ### The one thing this port had to change, and why

  Seven of core's self-contained blocks define modules that
  `test/aurora_meter/examples_test.exs` also defines, at its own top level, as
  verbatim transcriptions of the same guides. Compiling such a block would
  redefine a module another test file's assertions run against, and purging it
  afterwards would delete it outright. Both suites are `async: false`, and
  ExUnit does not order two synchronous modules, so the damage would depend on
  the seed: the definition of a flaky test.

  So a block whose top-level modules are **all** already loaded is not compiled
  here. It is not thereby unchecked: layers 1 to 3 still read it, and
  `examples_test.exs` compiles the same code for real and asserts against it.
  `@transcribed` names those modules, and each entry is asserted to still be
  defined by `examples_test.exs`, so the exemption dies with the transcription
  that justifies it rather than outliving it.

  Pro needed none of this, because Pro has no second file transcribing its
  guides.

  ### `Module.Name` spellings that are deliberately not modules

  `@not_modules` is Pro's mechanism, kept: a name a guide spells like a module
  and that is not one, each asserted to still not be a module so the list cannot
  outlive its reason.

  ### Aurora Meter Pro, named in a free package's guides

  Core's guides name Pro modules where the honest answer to "how do I bill
  this?" is "with the commercial package". Those modules are not loadable here
  and never will be: `architecture-map.md` rule 1 is that core never references
  a Pro module. So `@pro_modules` exempts them from layer 2 with the exemption
  **inverted**: each is asserted to be **absent** from core's build. If one ever
  loads, core has grown a dependency on Pro and this suite says so, which is a
  more useful failure than the one the exemption suppresses.

  ### A type is not a function

  Layer 3's regex cannot tell `AuroraMeter.Exporter.Item.t()` in a `@callback`
  from a call, so a module's own types are read out of its compiled typespecs
  and excluded by name. `docs/exporters.md` prints the two exporter callbacks
  verbatim, and a spec that names a type is the point of printing them.

  Reads files, compiles strings and reflects on loaded modules. It touches no
  database, but it is `async: false` because layer 4 puts modules into the code
  server that other synchronous suites also define.
  """
  use ExUnit.Case, async: false

  # Modules `test/aurora_meter/examples_test.exs` defines at its own top level,
  # transcribed verbatim from the guides. A block defining only these is read by
  # layers 1 to 3 and compiled by that file rather than by this one. See the
  # moduledoc.
  @transcribed [
    "Bramble.Plans",
    "Inkwell.Plans",
    "Parsely.Plans",
    "Lumen.Plans",
    "Lumen.Gateway",
    "MyApp.DailyPeriod",
    "MyApp.WeeklyPeriod"
  ]

  @transcriber "test/aurora_meter/examples_test.exs"

  # `{name, reason}`. A `Module.Name` spelling in the guides that is not a
  # module. Each is asserted to still not be one.
  @not_modules [
    {"AuroraMeter.TaskSupervisor",
     "a registered process name, not a module: Aurora Meter's own supervision " <>
       "tree starts a `Task.Supervisor` under it, and the hold reconciler's " <>
       "callback runs in a task on it"}
  ]

  # `AuroraMeter.Pro.*` names the guides use to point at the commercial package.
  # Asserted **absent** from core rather than present: see the moduledoc.
  @pro_modules_prefix "AuroraMeter.Pro"

  @operations "docs/operations.md"

  # Calls that change something an operator is correcting.
  @mutations [
    "expire_due(",
    "reconcile_holds(",
    "Retention.prune(",
    "Replay.run(",
    "forget_node(",
    "Operations.pause(",
    "Operations.resume("
  ]

  # Calls that only look.
  @read_only [
    "pending_holds(",
    "Retention.plan(",
    "Retention.status(",
    "Replay.status(",
    "Operations.list(",
    "Operations.checkpoint(",
    "Operations.paused?("
  ]

  # Sections the look-then-act rule does not apply to, keyed to the heading and
  # asserted to still exist. Section 1 is the inventory of what runs on a
  # schedule: its block names three operations in a row because it is a list of
  # what to schedule, not a procedure for correcting anything.
  @not_a_procedure ["## 1. What runs, and how often"]

  describe "the guides" do
    test "every elixir block parses" do
      failures =
        for block <- blocks(),
            {:error, message} <- [parse(block)],
            do: "#{block.file}:#{block.line} #{message}"

      assert failures == [],
             "elixir blocks that are not Elixir:\n  " <> Enum.join(failures, "\n  ")
    end

    test "every AuroraMeter module a block names exists" do
      missing =
        for block <- blocks(),
            name <- module_references(block.body),
            name not in Enum.map(@not_modules, &elem(&1, 0)),
            not pro?(name),
            module = Module.concat([name]),
            not Code.ensure_loaded?(module),
            do: "#{block.file}:#{block.line} #{name}"

      assert missing == [],
             "guides name modules that do not exist:\n  " <> Enum.join(Enum.uniq(missing), "\n  ")
    end

    test "every Pro module a core guide names is absent from core, which is the boundary" do
      named =
        for block <- blocks(),
            name <- module_references(block.body),
            pro?(name),
            do: {block.file, name}

      assert named != [],
             "no core guide names an Aurora Meter Pro module any more. Either the guides " <>
               "stopped mentioning the commercial package, or the scan broke; this " <>
               "exemption class should then be deleted rather than left standing"

      present =
        for {file, name} <- Enum.uniq(named),
            Code.ensure_loaded?(Module.concat([name])),
            do: "  #{file}: #{name}"

      assert present == [],
             "an AuroraMeter.Pro module is loadable inside aurora_meter's own suite. Core " <>
               "never references a Pro module (architecture-map.md rule 1), so this is a " <>
               "boundary violation, not a documentation problem:\n" <> Enum.join(present, "\n")
    end

    test "every @not_modules entry carries a reason and is still not a module" do
      for {name, reason} <- @not_modules do
        assert is_binary(reason) and String.trim(reason) != "",
               "#{name} is exempt from the module check with no reason"

        refute Code.ensure_loaded?(Module.concat([name])),
               "#{name} is a real module now, so its exemption is stale and must be deleted"
      end
    end

    test "every AuroraMeter function a block calls is exported" do
      missing =
        for block <- blocks(),
            {name, fun} <- function_references(block.body),
            not pro?(name),
            module = Module.concat([name]),
            Code.ensure_loaded?(module),
            not exported_at_any_arity?(module, fun),
            not type?(module, fun),
            do: "#{block.file}:#{block.line} #{name}.#{fun}"

      assert missing == [],
             "guides call functions that do not exist:\n  " <>
               Enum.join(Enum.uniq(missing), "\n  ")
    end

    test "every self-contained block compiles" do
      compiled =
        for block <- blocks(), self_contained?(block.body) do
          case compile(block) do
            :ok -> :ok
            {:error, message} -> "#{block.file}:#{block.line} #{message}"
          end
        end

      failures = Enum.reject(compiled, &(&1 == :ok))

      assert failures == [],
             "self-contained blocks that do not compile:\n  " <> Enum.join(failures, "\n  ")

      assert length(compiled) >= 8,
             "only #{length(compiled)} blocks were compiled; the guides used to have at " <>
               "least eight self-contained ones that examples_test.exs does not " <>
               "transcribe, so either they were rewritten or the detection broke"
    end

    test "every transcribed module is still defined by examples_test.exs" do
      source = File.read!(@transcriber)

      stale =
        for name <- @transcribed,
            not String.contains?(source, "defmodule #{name} do"),
            do: "  #{name}"

      assert stale == [],
             "#{@transcriber} no longer defines these modules, so exempting their guide " <>
               "blocks from layer 4 exempts nothing and hides a gap. Delete the entry and " <>
               "let this suite compile the block:\n" <> Enum.join(stale, "\n")
    end

    # `docs/operations.md`'s structural rule, and the one an operator's safety
    # rests on: look, then decide, then act. A block that changes state is
    # preceded, in the same `##` section, by a block that only reads.
    test "every mutation example in the operations guide follows a read-only one" do
      offenders =
        for {heading, blocks} <- sections(@operations),
            heading not in @not_a_procedure,
            {block, index} <- Enum.with_index(blocks),
            fun <- @mutations,
            String.contains?(block, fun),
            not Enum.any?(Enum.take(blocks, index), &read_only?/1),
            do: "  #{heading}: #{fun} with no read-only block before it"

      assert offenders == [],
             "a mutation is shown before anything that looks at what it is about to " <>
               "change. Every section that acts on state shows the look first:\n" <>
               Enum.join(Enum.uniq(offenders), "\n")
    end

    test "the sections exempt from the look-then-act rule still exist and are still lists" do
      source = File.read!(@operations)

      for heading <- @not_a_procedure do
        assert String.contains?(source, heading),
               "#{heading} is not in #{@operations} any more, so its exemption from the " <>
                 "look-then-act rule is stale and must be deleted rather than left standing"
      end
    end

    # Acceptance criterion 9 of build unit 05e: a core-only host reading a
    # runbook that tells them to inspect a Pro table has been handed a dead end.
    test "the core operations guide names no Pro module, table or configuration key" do
      source = File.read!(@operations)

      leaks =
        for needle <- [
              "AuroraMeter.Pro",
              "aurora_meter_pro",
              "aurora_meter_outbox_items",
              "aurora_meter_usage_reports",
              "aurora_meter_reconciliation_items",
              "aurora_meter_recovery_actions",
              "aurora_meter_audit_events",
              "aurora_meter_credit_accounts"
            ],
            String.contains?(source, needle),
            do: "  #{needle}"

      assert leaks == [],
             "#{@operations} names something only Aurora Meter Pro has. Core's runbook has " <>
               "to be complete on its own terms:\n" <> Enum.join(leaks, "\n")
    end

    # `open-findings.md` X227: P12's third copy of the hourly reporter schedule
    # was in this package's examples, where every inventory of P12 had looked
    # only in Pro. Pro's own scheduler_map_test guards Pro's pages; this guards
    # ours, because the finding was scoped to one package and the copy nobody
    # was looking for is the one that was still wrong.
    test "no published page schedules anything hourly, which is what P12 was about" do
      hourly =
        for path <- guide_files() ++ ["README.md"],
            File.exists?(path),
            File.read!(path) =~ "{\"0 * * * *\"",
            do: "  #{path}"

      assert hourly == [],
             "these pages carry the hourly crontab expression P12 was about:\n" <>
               Enum.join(Enum.uniq(hourly), "\n")
    end

    test "the guides hold the blocks this suite thinks they do" do
      # A floor, not an exact count: a guide may gain an example. It fails when
      # a whole guide stops being scanned, which is the silent failure.
      assert length(blocks()) >= 170, "only #{length(blocks())} elixir blocks were found"

      operations = Enum.filter(blocks(), &(&1.file == "docs/operations.md"))

      assert length(operations) == 12,
             "docs/operations.md has #{length(operations)} elixir blocks, not the 12 that " <>
               "05e wrote"

      # The scan is driven by mix.exs, so a guide dropped from the published set
      # silently leaves it. These are the pages an operator is sent to.
      for required <- [
            "README.md",
            "docs/operations.md",
            "docs/operations/scheduler.md",
            "docs/operations/replay.md",
            "docs/retention.md",
            "docs/credits.md"
          ] do
        assert Enum.any?(blocks(), &(&1.file == required)),
               "#{required} contributed no elixir block, so it is either not in mix.exs's " <>
                 "extras or it has stopped carrying examples"
      end
    end
  end

  # -- block extraction ------------------------------------------------------

  # The guides are exactly the pages that ship: the `docs/` extras from
  # `mix.exs`, plus the README, which is the docs main page. Reading mix.exs
  # rather than globbing means adding a guide to the published set adds it to
  # this check, and that an internal runbook such as `docs/RELEASE.md`, which is
  # not published and holds deliberate fragments, is not scanned.
  defp guide_files do
    extras =
      Mix.Project.config()[:docs][:extras]
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(String.starts_with?(&1, "docs/") and String.ends_with?(&1, ".md")))

    Enum.sort(["README.md" | extras])
  end

  defp blocks do
    for path <- guide_files(),
        File.exists?(path),
        block <- fenced(path, File.read!(path)),
        do: block
  end

  defp fenced(path, source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({nil, []}, fn {line, number}, {open, acc} ->
      trimmed = String.trim(line)

      cond do
        is_nil(open) and trimmed == "```elixir" -> {{number, []}, acc}
        is_nil(open) -> {nil, acc}
        trimmed == "```" -> close(path, open, acc)
        true -> {{elem(open, 0), [line | elem(open, 1)]}, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp close(path, {start, body}, acc) do
    {nil, [%{file: path, line: start, body: body |> Enum.reverse() |> Enum.join("\n")} | acc]}
  end

  # -- sections, for the look-then-act rule ----------------------------------

  # `[{heading, [block body, ...]}]` in document order, split on `## `. A `###`
  # subsection belongs to its parent, which is what makes "Forgetting a node"
  # part of the retention section rather than a procedure of its own.
  defp sections(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({nil, [], nil, []}, &section_line/2)
    |> finish_sections()
  end

  defp section_line(line, {heading, blocks, open, acc}) do
    trimmed = String.trim(line)

    cond do
      is_nil(open) and String.starts_with?(line, "## ") ->
        {trimmed, [], nil, push_section(heading, blocks, acc)}

      is_nil(open) and trimmed == "```elixir" ->
        {heading, blocks, [], acc}

      is_nil(open) ->
        {heading, blocks, nil, acc}

      trimmed == "```" ->
        {heading, [open |> Enum.reverse() |> Enum.join("\n") | blocks], nil, acc}

      true ->
        {heading, blocks, [line | open], acc}
    end
  end

  defp push_section(nil, _blocks, acc), do: acc
  defp push_section(heading, blocks, acc), do: [{heading, Enum.reverse(blocks)} | acc]

  defp finish_sections({heading, blocks, _open, acc}) do
    heading |> push_section(blocks, acc) |> Enum.reverse()
  end

  defp read_only?(block), do: Enum.any?(@read_only, &String.contains?(block, &1))

  # -- the four layers -------------------------------------------------------

  defp parse(block) do
    Code.string_to_quoted!(block.body)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp module_references(body) do
    ~r/\bAuroraMeter(?:\.[A-Z][A-Za-z0-9_]*)*\b/
    |> Regex.scan(body)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end

  defp function_references(body) do
    ~r/\b(AuroraMeter(?:\.[A-Z][A-Za-z0-9_]*)*)\.([a-z_][A-Za-z0-9_?!]*)\s*\(/
    |> Regex.scan(body)
    |> Enum.map(fn [_, module, fun] -> {module, String.to_atom(fun)} end)
    |> Enum.uniq()
  end

  defp exported_at_any_arity?(module, fun) do
    exports = module.__info__(:functions) ++ module.__info__(:macros)
    Enum.any?(exports, fn {name, _arity} -> name == fun end)
  end

  defp pro?(name), do: String.starts_with?(name, @pro_modules_prefix)

  # `AuroraMeter.Exporter.Item.t()` inside a printed `@callback` is a type, and
  # layer 3's regex cannot see the difference from text. Read the module's own
  # typespecs instead of guessing from the surrounding line.
  defp type?(module, fun) do
    case Code.Typespec.fetch_types(module) do
      {:ok, types} -> Enum.any?(types, fn {_kind, {name, _def, _args}} -> name == fun end)
      :error -> false
    end
  end

  # "Self-contained" is decided by content: every non-blank top-level line is
  # part of a `defmodule`. Nothing else in these guides can be compiled without
  # inventing a context for it.
  defp self_contained?(body) do
    lines = body |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))

    tops = Enum.filter(lines, &(not String.starts_with?(&1, " ")))

    only_modules? =
      tops != [] and
        Enum.all?(tops, fn line ->
          String.starts_with?(line, "defmodule ") or String.trim(line) == "end"
        end)

    only_modules? and uses_resolve?(body) and not transcribed?(body)
  end

  # `use InkwellWeb, :live_view` names the host's own web module. A guide that
  # shows a LiveView is not wrong; it simply cannot be compiled outside the
  # application it is written for, and pretending otherwise would mean either a
  # stub module or a skip list.
  defp uses_resolve?(body) do
    ~r/^\s*use\s+([A-Z][A-Za-z0-9_.]*)/m
    |> Regex.scan(body)
    |> Enum.all?(fn [_, name] -> Code.ensure_loaded?(Module.concat([name])) end)
  end

  # See the moduledoc. Every module the block declares is one
  # `examples_test.exs` transcribes and compiles itself.
  defp transcribed?(body) do
    declared = declared_modules(body)

    declared != [] and Enum.all?(declared, &(&1 in @transcribed))
  end

  defp declared_modules(body) do
    ~r/^defmodule\s+([A-Z][A-Za-z0-9_.]*)\s+do\s*$/m
    |> Regex.scan(body)
    |> Enum.map(fn [_, name] -> name end)
  end

  defp compile(block) do
    {result, _io} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        try do
          {:ok, Code.compile_string(block.body, "#{block.file}:#{block.line}")}
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    case result do
      {:ok, modules} ->
        on_exit_purge(modules)
        :ok

      {:error, message} ->
        {:error, message}
    end
  end

  defp on_exit_purge(modules) do
    on_exit(fn ->
      for {module, _binary} <- modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)
  end
end
