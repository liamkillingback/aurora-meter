defmodule AuroraMeter.Install.Shell do
  @moduledoc false
  # The two adjustments both Aurora Meter installers make to the way an Igniter
  # task talks to the shell it was run from. Both were found by running the
  # installer the way a host runs it rather than the way its tests do: from a
  # script, with no terminal (repair unit R5).
  #
  # Public because Aurora Meter Pro's installer lives in the other package, the
  # same reason `AuroraMeter.Install.Oban` is public. Compiled unconditionally,
  # with no reference to Igniter, so the headless build tests it too.

  @doc """
  Passes `result` through, unless it is `:issues`, in which case it exits 1.

  `result` is whatever `Igniter.do_or_dry_run/2` returned: `:changes_made`,
  `:no_changes`, `:dry_run_with_changes`, `:dry_run_with_no_changes`,
  `:changes_aborted` or `:issues`.

  **X366.** `Igniter.add_issue/2` is the documented way for a task to abort, and
  it works: `do_or_dry_run/2` matches `%{issues: []}` and everything with issues
  falls through to `display_issues/1` and a `:issues` return. **It sets no exit
  status**, so a task that refuses prints its refusal, writes nothing, and exits
  0, and no script can tell that from a success. Measured against a real host
  project by build unit 09b, left open there because the fix looked like a
  framework-level decision.

  It is not one. `Igniter.Mix.Task.__using__/1` ends with
  `defoverridable run: 1`, so a task may wrap its own `run/1`, read what
  `do_or_dry_run/2` has already told it, and say what that means. Nothing in the
  refusal path changes: the issues have been displayed by the time this is
  called and the only thing added is the status.

  `exit({:shutdown, 1})` and not `Mix.raise/1`, because `Kernel.CLI` halts with
  the integer (this is how `mix test` reports a failing suite) and the refusal
  has already been printed in the shape Igniter prints it. Raising would put a
  second, redundant error after it.
  """
  @spec halt_on_issues(term()) :: term()
  def halt_on_issues(:issues), do: exit({:shutdown, 1})
  def halt_on_issues(result), do: result

  @doc """
  Drops the `--yes` Igniter infers for a non-interactive run, when the run is a
  `--dry-run` and the operator did not type `--yes` themselves.

  Takes and returns the task's `Igniter.Mix.Task.Args`, typed as a plain map so
  that this can be exercised on a build that has no Igniter, which is the build
  where nobody would otherwise look at it.

  **X376.** `Igniter.Mix.Task.set_yes/2` puts `yes: true` into the options of
  any run whose `/dev/stdin` is not a character device, which is every run in
  CI, in a pipeline and under a script. `Igniter.do_or_dry_run/2` then reaches
  `display_diff/2`, which is `if !opts[:yes]`, and prints nothing. So the plain

      mix aurora_meter.install --dry-run

  wrote no file, which is right, and reported no change set, which is the only
  reason to run it, in exactly the place a host would run it. The switch's own
  documentation says it "prints the diff the task would apply".

  `--yes` means "do not stop to ask me before you write". A dry run writes
  nothing and returns before the confirmation is reached, so the inferred one has
  nothing to agree to here and its only effect is to hide the answer. An explicit
  `--yes` is left alone: that operator asked for the quiet form.
  """
  @spec report_dry_run(map()) :: map()
  def report_dry_run(%{options: options, argv: argv} = args) do
    if options[:dry_run] && "--yes" not in argv do
      %{args | options: Keyword.put(options, :yes, false)}
    else
      args
    end
  end
end
