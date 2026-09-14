defmodule Mix.Tasks.AuroraMeter.Events.Backfill do
  @shortdoc "Gives every pre-1.0 usage event the identity core schema 8 requires"

  @moduledoc """
  Fills `event_id`, `payload_hash`, `occurred_at`, `period_start` and
  `attribution` on every `aurora_meter_events` row written before core schema
  version 7.

      mix aurora_meter.events.backfill -r MyApp.Repo

  Run it **between** core schema version 7 and version 8. Version 8 makes
  `event_id` `NOT NULL` behind a unique index and refuses to run while any row
  still has a null one.

  It is bounded, checkpointed and safe to re-run: the cursor lives in
  `aurora_meter_checkpoints` under `"events_backfill"`, every update carries
  `WHERE event_id IS NULL`, and the identity of a legacy row is derived from
  its own primary key, so two runs produce the same bytes. Killing it loses at
  most the batch in flight.

  ## Options

    * `-r`, `--repo`: the repo to work through. Defaults to the configured one.
    * `--batch-size N`: rows per transaction. Default 5000.
    * `--max-batches N`: stop cleanly after N committed batches, for a bounded
      maintenance window. Re-run to continue.
    * `--dry-run`: scan and compute, change nothing, print the counts. Use it
      to see `nonpositive_quantity` and `oversized_metadata` before deciding
      whether version 8 can validate the check constraints.
    * `--force-resume`: proceed although the checkpoint says `"running"`,
      which is what a previous run killed mid-batch leaves behind.
    * `--stale-after N`: seconds after which such a checkpoint is described as
      stale in the refusal message. Default 900. It changes no behaviour: the
      refusal itself is decided by a Postgres advisory lock, never by a clock.
    * `--timeout N`: milliseconds allowed for one statement and one batch
      transaction. Default 60000. Raise it alongside `--batch-size`: the
      database driver would otherwise apply its own 15 second default, which is
      a sensible bound for a request and the wrong one for bulk work.

  ## What it approximates

  `occurred_at` is set to `inserted_at`, because `AuroraMeter.track/4` never
  recorded when the usage happened. Those rows are exactly the ones whose
  `event_id` begins `legacy:`. Where the period source cannot place the
  instant, `period_start` is the calendar month containing it and `attribution`
  is `"unresolved"`; every other backfilled row is `"resolved"`. Nothing else
  is guessed, and no row is projected into `aurora_meter_event_totals`: a
  legacy event was never billed and must not become billable by being upgraded.
  """

  use Mix.Task

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Events.Backfill

  @switches [
    batch_size: :integer,
    max_batches: :integer,
    dry_run: :boolean,
    force_resume: :boolean,
    stale_after: :integer,
    timeout: :integer,
    repo: [:keep, :string]
  ]

  @aliases [r: :repo]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    repo = repo!(args)
    Mix.Ecto.ensure_repo(repo, args)

    run_opts =
      opts
      |> Keyword.take([:batch_size, :max_batches, :dry_run, :force_resume, :timeout])
      |> Keyword.put(:repo, repo)

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> Backfill.run(run_opts) end)

    report(result, repo, Keyword.get(opts, :stale_after, 900), Keyword.get(opts, :dry_run, false))
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

  defp report({:ok, counts}, _repo, _stale_after, dry_run?) do
    Mix.shell().info(header(dry_run?))

    for key <- ~w(scanned updated already_filled resolved unresolved nonpositive_quantity
                  oversized_metadata batches cursor started_at finished_at) do
      Mix.shell().info("  #{String.pad_trailing(key, 22)} #{format(counts[key])}")
    end

    reasons = counts["unresolved_reasons"] || %{}

    for {reason, count} <- Enum.sort(reasons) do
      Mix.shell().info("  unresolved because     #{reason}: #{count}")
    end

    advise(counts, dry_run?)
    :ok
  end

  defp report({:error, :paused, _counts}, _repo, _stale_after, _dry_run?) do
    Mix.shell().info(
      "aurora_meter.events.backfill is paused. Nothing was changed. Clear it with " <>
        "AuroraMeter.Checkpoints.resume(\"events_backfill\") and run this again."
    )

    :ok
  end

  defp report({:error, :already_running, _counts}, repo, stale_after, _dry_run?) do
    Mix.shell().info(
      "aurora_meter.events.backfill is already running on another connection, which holds " <>
        "the advisory lock. Nothing was changed. Wait for it; --force-resume cannot take a " <>
        "lock that is held." <> age(repo, stale_after)
    )

    :ok
  end

  defp report({:error, :stale_running, counts}, repo, stale_after, _dry_run?) do
    Mix.shell().info(
      "aurora_meter.events.backfill's checkpoint says \"running\" but nothing holds the " <>
        "advisory lock, so a previous run was killed. Nothing was changed. Re-run with " <>
        "--force-resume to continue from seq #{counts["cursor"]}." <> age(repo, stale_after)
    )

    :ok
  end

  defp header(true), do: "aurora_meter.events.backfill (dry run, nothing was written):"
  defp header(false), do: "aurora_meter.events.backfill:"

  defp format(nil), do: "-"
  defp format(value), do: to_string(value)

  defp advise(counts, dry_run?) do
    if counts["nonpositive_quantity"] > 0 or counts["oversized_metadata"] > 0 do
      Mix.shell().info(
        "\nThese rows predate the V1 contract and were given identity anyway, but core " <>
          "schema version 8 cannot prove the quantity and metadata-size constraints against " <>
          "them. Either resolve the rows, or run version 8 with `validate_checks: false`, " <>
          "which leaves those constraints NOT VALID (still enforced on every new row) and " <>
          "records that in the schema marker."
      )
    end

    if not dry_run? and counts["unresolved"] > 0 do
      Mix.shell().info(
        "\n#{counts["unresolved"]} rows have an approximated billing period " <>
          "(attribution = 'unresolved'). Their period is the calendar month containing the " <>
          "instant, because the configured period source could not place it."
      )
    end
  end

  # Purely descriptive. Both sides of this comparison come from the database's
  # clock (the column is stamped with `clock_timestamp()`), and the threshold is
  # minutes, well clear of the sub-second backwards steps that clock takes. It
  # decides nothing: the refusal above was decided by an advisory lock.
  defp age(repo, stale_after) do
    case Checkpoints.get(Backfill.checkpoint_name(), repo: repo) do
      nil ->
        ""

      checkpoint ->
        seconds = DateTime.diff(AuroraMeter.Clock.db_now(), checkpoint.updated_at)

        if seconds > stale_after do
          " The checkpoint has said \"running\" for #{seconds}s, which is longer than the " <>
            "#{stale_after}s you called stale, and yet the lock is still held, so a runner " <>
            "really is alive. Find it before forcing anything."
        else
          " The checkpoint was last written #{seconds}s ago."
        end
    end
  end
end
