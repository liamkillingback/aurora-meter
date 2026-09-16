defmodule AuroraMeter.InstallShellTest do
  @moduledoc """
  The two edges of an Igniter task that Aurora Meter's installers override, and
  the `--oban` support question.

  **Deliberately not in `test/mix/tasks/install_test.exs`.** That file is guarded
  on `Code.ensure_loaded?(Igniter.Test)` and does not compile on the `headless`
  CI leg, and `Igniter.Test` exercises a task's `igniter/1` rather than its
  `run/1`, so neither the exit status nor the dry-run report is reachable from
  there at all. Everything here is a plain function taking plain data for exactly
  that reason: the three states being asserted are three this package's own suite
  can never be in, which is how all three survived build unit 09b (repair unit
  R5, `open-findings.md` X366, X375, X376).
  """
  use ExUnit.Case, async: true

  alias AuroraMeter.Install.Shell
  alias AuroraMeter.Install.Support
  alias AuroraMeter.Install.Templates

  describe "halt_on_issues/1 (X366)" do
    test "a refusal exits 1" do
      assert catch_exit(Shell.halt_on_issues(:issues)) == {:shutdown, 1}
    end

    test "control: every other outcome Igniter returns passes straight through" do
      # Without this the assertion above would pass for a function that exited on
      # anything, which is a worse defect than the one it is fixing: an installer
      # that wrote every file and then reported failure.
      for result <- [
            :changes_made,
            :no_changes,
            :dry_run_with_changes,
            :dry_run_with_no_changes,
            :changes_aborted
          ] do
        assert Shell.halt_on_issues(result) == result
      end
    end
  end

  describe "report_dry_run/1 (X376)" do
    # `Igniter.Mix.Task.set_yes/2` puts `yes: true` into any run whose
    # `/dev/stdin` is not a character device, and `Igniter.do_or_dry_run/2` skips
    # `display_diff/2` when `:yes` is set, so `--dry-run` in a script printed
    # nothing whatsoever.
    test "a dry run in a script gets its inferred --yes dropped" do
      args = %{options: [dry_run: true, yes: true], argv: ["--repo", "Demo.Repo", "--dry-run"]}

      assert Shell.report_dry_run(args).options[:yes] == false
    end

    test "an operator who typed --yes keeps the quiet form they asked for" do
      args = %{
        options: [dry_run: true, yes: true],
        argv: ["--repo", "Demo.Repo", "--dry-run", "--yes"]
      }

      assert Shell.report_dry_run(args).options[:yes] == true
    end

    test "control: a run that is not a dry run is not touched" do
      # The whole point of the narrowing. A real run's inferred `--yes` is what
      # keeps a non-interactive install from blocking on a confirmation prompt
      # forever, so flipping it there would hang every scripted install.
      args = %{options: [yes: true], argv: ["--repo", "Demo.Repo"]}

      assert Shell.report_dry_run(args) == args
      assert Shell.report_dry_run(args).options[:yes] == true
    end

    test "a dry run at a terminal, where Igniter inferred nothing, is unchanged" do
      args = %{options: [dry_run: true], argv: ["--dry-run"]}

      assert Shell.report_dry_run(args).options[:yes] == false
    end
  end

  describe "--oban on a host that cannot have it (X375)" do
    test "I20 no Oban at all: the message names the line to add to mix.exs" do
      assert {:error, message} = Support.oban_switch(false, false)

      assert message =~ ~s({:oban, "~> 2.17"})
      assert unwrap(message) =~ "does not have Oban"
      assert message =~ "Nothing was written."

      # And it does not answer in the vocabulary of the package's internals,
      # which is what the UndefinedFunctionError it replaces did: a host cannot
      # install `AuroraMeter.Oban`, it can only install `oban`.
      refute message =~ "AuroraMeter.Oban"
    end

    test "I20 Oban present and the workers not compiled: the stale build, and the one line that fixes it" do
      assert {:error, message} = Support.oban_switch(true, false)

      assert message =~ "mix deps.compile aurora_meter --force"
      assert message =~ "Nothing was written."

      # Whitespace normalised: the sentence is wrapped for a terminal and where
      # it wraps is not what this test is about.
      assert unwrap(message) =~ "workers are not compiled into this build"
    end

    test "I20 control: a host that has both is not refused" do
      # Without this the two assertions above would pass for a function that
      # refused every host, and `--oban` would be dead on every host instead of
      # broken on some.
      assert Support.oban_switch(true, true) == :ok
    end

    test "I20 the version the refusal asks for is the floor the support matrix declares" do
      # Not a literal. A refusal that invents the version it asks for is a
      # refusal that is wrong one release after the floor moves.
      assert Support.floor_for(:oban) == "2.17.0"
      assert {:oban, "2.17.0", :optional} in Support.declared_deps()
      assert Support.floor_for(:not_a_dependency) == nil
    end
  end

  describe "the queue name the installer writes" do
    test "I20 the two places it is written agree with each other" do
      assert Templates.oban_config(Demo.Repo, []) =~ "queues: [#{Templates.queue()}: 5]"
    end

    if Code.ensure_loaded?(AuroraMeter.Oban) do
      test "I20 and both agree with AuroraMeter.Oban.queue/0" do
        # `Templates.queue/0` exists because `AuroraMeter.Oban` is compiled only
        # when Oban is, and the installer is compiled whenever Igniter is, so the
        # direct call warned on every compile of the dependency in a host without
        # Oban (X375). A copy needs a test that it is still a copy, and this
        # build is one that can ask.
        assert Templates.queue() == AuroraMeter.Oban.queue()
      end
    end
  end

  defp unwrap(message), do: String.replace(message, ~r/\s+/, " ")
end
