defmodule Mix.Tasks.AuroraMeter.Credits.MigrateLots do
  @shortdoc "Replays legacy wallets into credit lots, and reports what it found"

  @moduledoc """
  Replays every wallet's ledger into `aurora_meter_credit_lots` and
  `aurora_meter_credit_allocations`, reconciles the result against the wallet's
  own balance row, and cuts the wallet over when the two agree exactly.

      mix aurora_meter.credits.migrate_lots -r MyApp.Repo

  Run it **after** core schema version 9 and after every node in the fleet is
  on a release that honours `lots_enabled_at`. A node on an older image ignores
  the column and would keep writing legacy arithmetic to a wallet the allocator
  now owns; no code can detect that, so it is an operator step. This task
  refuses to start below version 9 and prints the requirement.

  It is **shadow by default**: it computes and reports and writes nothing
  except checkpoint rows. That is the run to read first.

  ## A real cutover is currently refused

  `AuroraMeter.Credits.reverse/4` does not take the lot path yet, so a paid
  refund on a cut-over wallet would consume promotional lots in spend order.
  `--no-shadow` therefore stops with an explanation rather than turning a
  wallet on. Everything else works today: the replay, the reconciliation, the
  per-wallet report and the list of wallets that cannot be migrated are all
  produced by the shadow run.

  ## Options

    * `-r`, `--repo`: the repo to work through. Defaults to the configured one.
    * `--shadow` / `--no-shadow`: shadow is the default. `--no-shadow` asks for
      a real cutover and is refused while the refund path is unwired.
    * `--tenant KEY`: one wallet. Repeatable.
    * `--batch N`: wallets per aggregate checkpoint write. Default 50.
    * `--no-resume`: start from the first wallet instead of the cursor.
    * `--max-rows N`: a wallet with more ledger rows than this is deferred and
      paused rather than migrated under a long lock. Default 50000.
    * `--max-tail N`: rows committed during the snapshot that will be folded in
      under the lock before the wallet is deferred as busy. Default 500.
    * `--max-wallets N`: wallets one run examines. Default 100000.
    * `--retry-blocked`: reprocess wallets a previous run reported blocked, and
      wallets an operator paused.
    * `--report-only`: also report wallets that are already migrated.

  ## Exit status

  Non-zero when any wallet was blocked, so a runner cannot report success while
  wallets were left behind. The summary names every one of them and why.

  ## What a blocked wallet means

  Nothing was written for it and nothing was changed. It keeps working on the
  legacy writer indefinitely. The reason is on its checkpoint row, readable
  with `AuroraMeter.Credits.LotMigration.status/1`. See
  `docs/upgrading-to-lots.md` for what each reason means and what to do.
  """

  use Mix.Task

  alias AuroraMeter.Credits.LotMigration

  @switches [
    repo: [:keep, :string],
    shadow: :boolean,
    tenant: :keep,
    batch: :integer,
    resume: :boolean,
    max_rows: :integer,
    max_tail: :integer,
    max_wallets: :integer,
    retry_blocked: :boolean,
    report_only: :boolean
  ]

  @aliases [r: :repo]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    repo = repo!(args)
    Mix.Ecto.ensure_repo(repo, args)

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> LotMigration.run(run_opts(opts, repo)) end)

    report(result)
  end

  defp run_opts(opts, repo) do
    opts
    |> Keyword.take([
      :shadow,
      :batch,
      :resume,
      :max_rows,
      :max_tail,
      :max_wallets,
      :retry_blocked,
      :report_only
    ])
    |> Keyword.put(:repo, repo)
    |> Keyword.put(:tenant, tenants(opts))
    |> Keyword.put_new(:shadow, true)
    |> then(&Keyword.put(&1, :allow_cutover, &1[:shadow] == false))
  end

  defp tenants(opts) do
    case Keyword.get_values(opts, :tenant) do
      [] -> nil
      keys -> keys
    end
  end

  defp repo!(args) do
    case Mix.Ecto.parse_repo(args) do
      [repo | _rest] ->
        repo

      [] ->
        Mix.raise(
          "no ecto repo found. Pass one with `-r MyApp.Repo`, or set `:ecto_repos` in your " <>
            "application configuration."
        )
    end
  end

  @doc """
  Prints one run's summary and decides the task's exit status.

  Public so the maintainer suite can assert the exit decision itself rather
  than a proxy for it: a run that left wallets behind must fail, and a test
  that only checked the printed text would pass for a task that exited 0.
  """
  @spec report({:ok, AuroraMeter.Credits.LotMigration.summary()} | {:error, term()}) :: :ok
  def report({:ok, summary}) do
    Mix.shell().info(header(summary))

    for key <- ~w(wallets migrated blocked deferred skipped rows lots allocations)a do
      Mix.shell().info("  #{String.pad_trailing(to_string(key), 14)} #{Map.fetch!(summary, key)}")
    end

    Mix.shell().info("  #{String.pad_trailing("lock ms max", 14)} #{summary.lock_ms_max}")
    Mix.shell().info("  #{String.pad_trailing("duration ms", 14)} #{summary.duration_ms}")

    detail(summary, :blocked, "blocked")
    detail(summary, :deferred, "deferred")
    quiescence(summary)
    fail_on_blocked(summary)
  end

  # Non-zero, deliberately. The operator asked for a cutover and did not get
  # one, and a task that answers that with exit 0 is a warning nobody reads.
  def report({:error, {:cutover_blocked, %{finding: finding, reason: reason}}}) do
    Mix.shell().info("""
    aurora_meter.credits.migrate_lots will not cut a wallet over yet.

    #{reason}

    Nothing was read and nothing was written. Run it without --no-shadow to
    take the whole replay and reconciliation now; the cutover is a separate
    decision and it needs the lot-aware refund path first (#{finding}).
    """)

    Mix.raise("aurora_meter.credits.migrate_lots: the cutover is refused (#{finding}).")
  end

  def report({:error, :cutover_not_requested}) do
    Mix.raise(
      "aurora_meter.credits.migrate_lots was given --no-shadow but no cutover was " <>
        "requested. Nothing was done."
    )
  end

  def report({:error, :schema_below_version_9}) do
    Mix.raise(
      "aurora_meter.credits.migrate_lots needs core schema version 9, which creates the lot " <>
        "tables and the `lots_enabled_at` column. Run `AuroraMeter.Migration.up(version: 9)` " <>
        "first."
    )
  end

  def report({:error, reason}),
    do: Mix.raise("aurora_meter.credits.migrate_lots: #{inspect(reason)}")

  defp header(%{shadow: true}),
    do: "aurora_meter.credits.migrate_lots (shadow, nothing financial was written):"

  defp header(%{shadow: false}), do: "aurora_meter.credits.migrate_lots:"

  defp detail(summary, state, label) do
    rows = Enum.filter(summary.reports, &(&1.state == state))

    unless rows == [] do
      Mix.shell().info("\n#{label} wallets:")

      for report <- rows do
        Mix.shell().info("  #{report.tenant_key}  #{reasons(report)}")
      end
    end
  end

  defp reasons(%{flags: [], reason: reason}), do: to_string(reason)

  defp reasons(%{flags: flags}) do
    flags
    |> Enum.filter(& &1.blocking)
    |> Enum.map_join(", ", &"#{&1.flag} #{inspect(&1.detail)}")
  end

  defp quiescence(%{shadow: true}), do: :ok

  defp quiescence(%{migrated: 0}), do: :ok

  defp quiescence(%{migrated: count}) do
    Mix.shell().info(
      "\n#{count} wallets are now owned by the allocator. Every node must already be on a " <>
        "release that honours `lots_enabled_at`: an older image ignores the column and would " <>
        "write legacy arithmetic over the lots, which the next conservation check would refuse."
    )
  end

  defp fail_on_blocked(%{blocked: 0}), do: :ok

  defp fail_on_blocked(%{blocked: count}) do
    Mix.raise(
      "#{count} wallets were not migrated. Nothing was written for them and they keep " <>
        "working on the legacy writer. The reasons are above and on each wallet's checkpoint " <>
        "row; see docs/upgrading-to-lots.md."
    )
  end
end
