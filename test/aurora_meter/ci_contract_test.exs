defmodule AuroraMeter.CIContractTest do
  @moduledoc """
  The parts of the CI contract that a machine can check from inside the suite.

  Build unit 01f owns `.github/workflows/ci.yml`, and a workflow is verified by
  running it. Three things about it are not, though: that the two suite aliases
  exist and mean what CI and `scripts/v1/verify.sh` both assume; that the tags
  those aliases select are still part of the ordinary `mix test` run; and that no
  step in the workflow can publish, deploy or tag. Each of those is an assertion
  about this repository's own source, so each is a test.

  See `docs/evidence/v1/phase-01/ci.md`.
  """
  use ExUnit.Case, async: true

  @aliases Mix.Project.config()[:aliases]
  @test_helper "test/test_helper.exs"
  @workflow ".github/workflows/ci.yml"

  describe "the suite aliases (the contract shared with scripts/v1)" do
    test "v1.migrations and v1.faults exist and each names a test run" do
      for name <- [:"v1.migrations", :"v1.faults"] do
        commands = Keyword.get(@aliases, name)

        assert is_list(commands),
               "mix.exs has no `#{name}` alias. CI and scripts/v1/verify.sh both " <>
                 "invoke it by name; if it is renamed here it must be renamed there."

        assert Enum.any?(commands, &String.starts_with?(&1, "test ")),
               "the `#{name}` alias does not run `test`: #{inspect(commands)}"
      end
    end

    test "v1.faults runs with a fixed seed, so a fault ordering is reproducible" do
      assert Enum.any?(Keyword.fetch!(@aliases, :"v1.faults"), &(&1 =~ "--seed 0"))
    end

    test "each alias selects a tag that at least one module actually carries" do
      # An alias whose tag matches nothing is not a quiet no-op: `mix test --only`
      # exits non-zero with "no test was executed". This test names the problem
      # before CI has to.
      for {alias_name, tag} <- [{:"v1.migrations", "migration"}, {:"v1.faults", "fault"}] do
        carriers =
          "test/**/*_test.exs"
          |> Path.wildcard()
          |> Enum.filter(&(File.read!(&1) =~ ~r/@moduletag\s+:#{tag}\b/))

        assert carriers != [],
               "`mix #{alias_name}` selects @moduletag :#{tag} and no test module " <>
                 "carries it, so the job would fail with \"no test was executed\". " <>
                 "Tag the suite that belongs to it."
      end
    end
  end

  describe "the excluded tags in test_helper.exs" do
    test ":fault and :migration are not excluded, so they run in the ordinary suite" do
      excluded = configured_exclusions()

      for tag <- [:fault, :migration] do
        refute tag in excluded,
               "#{inspect(tag)} is excluded in #{@test_helper}, so `mix test` would " <>
                 "skip it and `mix v1.#{tag}s` would become the only place it ever " <>
                 "ran. A skipped required suite is a failure."
      end
    end

    test ":headless is excluded, and it is the only exclusion" do
      assert configured_exclusions() == [:headless]
    end
  end

  describe "the workflow cannot publish, deploy or tag (invariant M5, decision D13)" do
    test "no step contains a publishing, deploying or tagging command" do
      lines =
        @workflow
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))

      for banned <- ["hex.publish", "hex.organization", "fly deploy", "git tag", "git push"] do
        offenders = Enum.filter(lines, &String.contains?(&1, banned))

        assert offenders == [],
               "#{@workflow} contains #{inspect(banned)} on a non comment line: " <>
                 "#{inspect(offenders)}. Releases and deployments are owner run."
      end
    end

    test "every runtime version in the workflow is an exact patch" do
      source = File.read!(@workflow)

      for {label, pattern} <- [
            {"elixir", ~r/^\s*(?:-\s*)?elixir(?:-version)?:\s*"([^"]+)"/m},
            {"otp", ~r/^\s*(?:-\s*)?otp(?:-version)?:\s*"([^"]+)"/m}
          ] do
        versions = pattern |> Regex.scan(source) |> Enum.map(fn [_, v] -> v end)
        assert versions != [], "no #{label} version found in #{@workflow}"

        for version <- versions do
          assert version =~ ~r/^\d+\.\d+(\.\d+)+$/ or String.contains?(version, "${{"),
                 "#{label} version #{inspect(version)} in #{@workflow} is not an " <>
                   "exact patch. A minor only pin makes a green run irreproducible."
        end
      end
    end

    test "the Postgres service images are pinned to an exact patch tag" do
      images =
        ~r/image:\s*(postgres:[^\s]+)/
        |> Regex.scan(File.read!(@workflow))
        |> Enum.map(fn [_, image] -> image end)
        |> Enum.uniq()

      assert images != []

      for image <- images do
        assert image =~ ~r/^postgres:\d+\.\d+$/,
               "#{image} is not an exact Postgres patch tag"
      end
    end
  end

  test "I20 every optional-dependency leg is in the matrix, and every one of them blocks" do
    # Build unit 09b, `open-findings.md` X246 and X356.
    #
    # The three legs below are the only things in this repository that build
    # the package with a dependency deliberately missing, and they are what
    # invariant I20 rests on. `AURORA_HEADLESS` was red at HEAD for two phases
    # and nothing said so: the leg exists, it is not `continue-on-error`, and
    # the workflow has never run (01f section 10, owner blocked). Three units
    # reported "the leg passes", each accurately describing a run it had
    # chosen to do by hand.
    #
    # This test cannot make CI run. What it can do is refuse the two silent
    # ways a leg stops being watched: being deleted, and being quietly marked
    # non-blocking. `docs/evidence/v1/phase-09/09b-optional-deps.md` records
    # what does run these legs today and why `mix check` is not the place.
    source = File.read!(@workflow)

    for leg <- ["headless", "plug_only", "liveview-1.0"] do
      assert source =~ ~r/^\s*- leg: #{Regex.escape(leg)}$/m,
             "the #{leg} leg is not in #{@workflow}. It is one of the three that " <>
               "builds this package with a dependency missing, and invariant I20 " <>
               "is a claim about exactly those builds."
    end

    # And none of them is `experimental: "yes"`, which is this workflow's
    # spelling of `continue-on-error`. A leg that cannot fail the run is a leg
    # that is not in the gate.
    # Split into one block per leg first. A single regex spanning from
    # `- leg:` to `experimental: "yes"` is not lazy enough to stay inside one
    # entry: it matches from the FIRST leg to the first "yes" anywhere after
    # it, and names the wrong leg. Measured, by flipping `headless` and
    # watching the failure say `["minimum"]`.
    experimental =
      source
      |> String.split(~r/^\s*- leg: /m)
      |> Enum.drop(1)
      |> Enum.filter(&(&1 =~ ~r/^\s*experimental: "yes"$/m))
      |> Enum.map(&(&1 |> String.split("\n") |> hd() |> String.trim()))

    assert experimental == [],
           "these legs are non-blocking: #{inspect(experimental)}. A leg is allowed " <>
             "to be non-blocking for exactly one merge, with the finding it captures " <>
             "named beside it; if one is here, either it has served its purpose and " <>
             "should go, or it is a failure nobody is watching."
  end

  test "I20 every AURORA_ switch a leg sets is one mix.exs actually reads" do
    # The other half: a leg can also stop testing what it says by naming a
    # switch nothing reads, which fails open and silently. Every
    # `AURORA_`-prefixed variable the workflow sets must appear in `mix.exs`,
    # which is where the switches take dependencies out.
    workflow = File.read!(@workflow)
    mix_exs = File.read!("mix.exs")

    switches =
      ~r/^\s*(AURORA_[A-Z_]+):/m
      |> Regex.scan(workflow)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()

    assert "AURORA_HEADLESS" in switches
    assert "AURORA_NO_LIVEVIEW" in switches

    for switch <- switches do
      assert String.contains?(mix_exs, switch),
             "#{@workflow} sets #{switch} and mix.exs never reads it, so the leg " <>
               "that switch names resolves the ordinary dependency set and tests " <>
               "nothing it claims to."
    end
  end

  # Parse test_helper.exs rather than reading ExUnit's runtime configuration:
  # `mix test --only fault` rewrites the runtime exclude list, so a runtime read
  # would answer a different question depending on how the suite was invoked.
  defp configured_exclusions do
    @test_helper
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {{:., _, [{:__aliases__, _, [:ExUnit]}, fun]}, _, args} = node, acc
      when fun in [:configure, :start] ->
        {node, acc ++ exclusions_from(args)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp exclusions_from([opts | _]) when is_list(opts) do
    case Keyword.fetch(opts, :exclude) do
      {:ok, tags} when is_list(tags) -> Enum.map(tags, fn tag -> tag end)
      _ -> []
    end
  end

  defp exclusions_from(_), do: []
end
