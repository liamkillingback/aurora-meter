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
