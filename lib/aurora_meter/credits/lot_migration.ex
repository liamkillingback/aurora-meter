defmodule AuroraMeter.Credits.LotMigration do
  @moduledoc """
  Replays a legacy wallet's ledger into lots and allocations, and cuts that
  wallet over to the allocator.

  This is schema-migration step S5: a **data** step against the tables core
  schema version 9 created. It adds no DDL. Run it with
  `mix aurora_meter.credits.migrate_lots`, or call `run/1` from a remote console
  on a release that has no Mix.

      AuroraMeter.Credits.LotMigration.run(shadow: true)
      AuroraMeter.Credits.LotMigration.status()

  ## What it does, per wallet

  1. **Snapshot**, holding no lock: read the wallet's ledger rows and fold them
     into a book of lots.
  2. **Lock**: take the balance row `FOR UPDATE`, re-read `lots_enabled_at`,
     read any rows committed since the snapshot and fold them in.
  3. **Verify**: compare the folded book's projection with the locked balance
     row's `balance`, `held` and `promotional`. Any mismatch, and any ambiguity
     the fold raised, blocks the wallet.
  4. **Write**: insert the lots and allocations, backfill
     `hold_transaction_id` on the settle and release rows, set `debt`,
     `expired` and `lots_enabled_at`, and run the allocator's conservation
     check as the last statement before commit.
  5. **Report**: one `aurora_meter_checkpoints` row per wallet, plus the run's
     own cursor row. A shadow run and a real run keep **separate** cursor rows,
     so a rehearsal can never tell the real migration that it has already
     covered ground it has not touched (`open-findings.md` X427).

  Steps 2 to 5 are one transaction, so a wallet is either entirely migrated or
  entirely untouched. Step 1 holds no lock, so a wallet with a long history
  costs the live path one short lock rather than a minutes-long stall.

  ## The balance row is the oracle

  The fold reproduces the arithmetic the legacy ledger performed, and then
  checks itself against numbers that ledger wrote: every row's `balance_after`,
  `held_after` and `promotional_after`, and finally the balance row itself.
  Those figures were computed by legacy arithmetic that knew nothing about
  lots, so they are an **independent** statement of the same facts rather than
  the fold's own arithmetic run twice. A wallet whose replay does not reproduce
  them exactly is never migrated, and is never adjusted to fit.

  ## What it never does

  It never writes `balance`, `held`, `promotional`, `currency` or
  `low_balance_threshold`; it never changes any historical column except
  `hold_transaction_id`, which was null; it deletes nothing; it contacts no
  provider and sends no mail. With `shadow: true`, which is the default, the
  only rows it writes at all are checkpoint rows, and the only cursor it writes
  is its own: a shadow run cannot change where the real migration starts.

  ## Reading a run that migrated nothing

  Two opposite situations used to print the same summary of zeros. The summary
  now separates them, and `run/1` reports both figures:

    * `resumed_from` is the cursor the scan started after, `nil` if it started
      at the beginning of the table;
    * `unexamined` counts wallets still on the legacy writer that this run did
      not look at and that no run of this mode has recorded a verdict for. It is
      `nil` when the caller named tenants explicitly.

  A run with `wallets: 0` and `unexamined: 0` had nothing to do. A run with
  `wallets: 0` and `unexamined` above zero **skipped wallets that still need
  migrating**, reports `state: "skipped_by_cursor"`, and the Mix task exits
  non-zero for it.

  ## Cutting a wallet over

  A real cutover was refused while there was no lot-aware refund path: a paid
  refund on a cut-over wallet would have gone through `reverse/4`, consumed
  promotional lots in spend order and written nothing into `reversed`
  (`open-findings.md` X250). `AuroraMeter.Credits.reverse_lot/4` is that path
  and is the gate's own condition, so from the release that carries it
  `shadow: false` is permitted and `cutover_blocked/0` answers `nil`.

  A host that still wants the refusal keeps `shadow: true`, which remains the
  default: `allow_cutover: true` has to be asked for explicitly on every run
  that writes.

  **Both refund paths are lot aware from repair unit R1**, and that is the
  correction this paragraph used to need. Opening the gate on `reverse_lot/4`
  alone left `reverse/4` planning a reversal as a debit, so a host that had no
  payment provenance, or an `aurora_meter_pro` fallback that could not match
  one, still took promotional credit first. `reverse/4` now takes the wallet's
  non-promotional lots in spend order and writes `reversed`, so a cut-over
  wallet is safe on either call. `reverse_lot/4` remains the right one to use
  where the payment is known, because only it is capped by that payment's own
  lots.

  ## Ordering

  A row written before schema version 9 has no sound order. `inserted_at` comes
  from a wall clock that steps backwards, and `seq` was assigned by version 9's
  table rewrite in physical order rather than insertion order. So the fold
  trusts neither: it folds in `(inserted_at, id)` order and checks the result
  against every row's own `balance_after` and `held_after`, which form an exact
  chain in true commit order. If that chain does not hold it folds again in
  `seq` order. If neither reproduces the chain, the wallet's history cannot be
  ordered from what it carries, and the wallet is blocked.
  """

  import Ecto.Query

  require Logger

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Credits.Allocator
  alias AuroraMeter.Operations
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Tenant

  # **Shadow and real keep separate cursors** (`open-findings.md` X427, repair
  # unit R8). The aggregate row is the resume point, and it belongs to the mode
  # that wrote it: a shadow run records how far it has rehearsed, a real run how
  # far it has cut over, and neither can be mistaken for the other.
  #
  # Before R8 there was one row. The guide's step 1 is a shadow run and its step
  # 4 is the real one, so the rehearsal walked every wallet, left the cursor on
  # the last one, and the real run that followed scanned `tenant_key > <last>`,
  # examined **zero** wallets and printed a clean summary. An operator following
  # our own documentation migrated nothing and was told it had worked.
  #
  # `architecture-map.md` 7.4 is binding and says shadow mode "computes and
  # reports without writing". The per-wallet rows are the report (the guide
  # sends the operator to `status/1` to read them), so they stay. The cursor is
  # not a report, it is **control state the next run obeys**, and a rehearsal
  # that changes what the real run does is the writing 7.4 forbids.
  #
  # The name cannot collide with a wallet's. `checkpoint_name/1` always emits
  # `"lot_migration:" <> something`, and `wallet_checkpoints/2` selects on that
  # prefix, so a row named `lot_migration_shadow` is reachable by neither, even
  # for a tenant whose key is literally "shadow".
  @aggregate "lot_migration"
  @aggregate_shadow "lot_migration_shadow"
  @prefix "lot_migration:"

  # The checkpoint states that mean "a run of this mode has been here and
  # decided". They are what `unexamined/4` counts against.
  #
  # A shadow run's verdicts do not count for a real run, and that asymmetry is
  # the whole point: `shadow_ok` means the replay reconciled, **not** that the
  # wallet was cut over. Letting it count would tell a real run that sixteen
  # legacy wallets had been dealt with when not one had, which is exactly the
  # sentence X427 is about.
  @settled_real ~w(migrated blocked deferred paused skipped)
  @settled_shadow @settled_real ++ ~w(shadow_ok shadow_blocked)

  # The operation-name shape `AuroraMeter.Operations` enforces. A tenant key is
  # host supplied and can hold anything at all, so a name built from one is
  # checked here rather than discovered by `pause/1` raising halfway through a
  # run (`open-findings.md` X221, X203).
  @name_format ~r/^[a-z_]+:[A-Za-z0-9_.:-]+$/

  # **The replay's instant, and there is exactly one.**
  #
  # The legacy ledger had no expiry-based eligibility at all: `sufficient?/2`
  # was `balance - held`, so a grant whose `expires_at` had passed but which
  # the sweep had not reached was still spendable, and the `expire` row that
  # finally took it is in the log where it happened. Passing the row's own
  # `inserted_at` as "now" would apply the **fixed** eligibility rule to
  # history, consume value the legacy ledger did not, and stop the replay
  # reproducing the balance row it is checked against.
  #
  # The fixed semantics apply from cutover onward, which is what
  # `v1-release.md` section 10.1 asks for. An instant before every lot's expiry
  # is how this fold says "no lot is expired except where the log says so". It
  # is not a clock: nothing here reads one, and nothing here orders by one.
  @legacy_now ~U[1970-01-01 00:00:00.000000Z]

  @contribution [:available, :reserved]

  @quantities [:available, :reserved, :consumed, :reversed, :expired]

  # Written by `aurora_meter_pro` up to 0.3.0 and matched here only to recover
  # provenance from historical rows. Core never calls Pro and never assumes it
  # is installed: a wallet whose rows match none of these simply has no
  # payment-intent provenance and is judged by the other rules.
  @reversal_prefixes ~w(refund: dispute: reconciled:)
  @restore_prefixes ~w(reconciled_restore: reinstated: refund_restored:)

  @payment_intent ~r/^(pi|py|ch)_[A-Za-z0-9_]+$/

  @blocking [
    :ledger_chain_mismatch,
    :history_out_of_order,
    :projection_mismatch,
    :promotional_divergence,
    :internal_projection_drift,
    :hold_unbacked,
    :orphan_settle,
    :orphan_release,
    :reversal_unattributed,
    :reversal_exceeds_lots,
    :reversal_took_reserved,
    :expire_unattributed,
    :expire_over_lot,
    :expire_reserved_grant,
    :unparsable_restore_reference,
    :unsupported_row,
    :exception
  ]

  # Reordering can only fix a disagreement about what happened when.
  @order_sensitive [:ledger_chain_mismatch, :promotional_divergence]

  @schema [
    repo: [type: :atom, doc: "The repo to work through. Defaults to the configured one."],
    shadow: [type: :boolean, default: true, doc: "Compute and report, write nothing financial."],
    tenant: [type: :any, default: nil, doc: "One tenant term, or a list of them."],
    batch: [type: :pos_integer, default: 50, doc: "Wallets per aggregate checkpoint write."],
    resume: [
      type: :boolean,
      default: true,
      doc: "Continue from this mode's own cursor. Shadow and real keep separate ones."
    ],
    max_rows: [type: :pos_integer, default: 50_000, doc: "Defer a wallet larger than this."],
    max_tail: [type: :non_neg_integer, default: 500, doc: "Rows folded in under the lock."],
    max_wallets: [type: :pos_integer, default: 100_000, doc: "Wallets one run examines."],
    retry_blocked: [type: :boolean, default: false, doc: "Reprocess wallets reported blocked."],
    report_only: [type: :boolean, default: false, doc: "Report an already migrated wallet too."],
    allow_cutover: [type: :boolean, default: false, doc: "Ask for a real cutover."]
  ]

  @typedoc "What one wallet's replay concluded."
  @type verdict :: :migrated | :blocked | :deferred | :shadow_ok | :skipped

  @typedoc "One ambiguity or observation the fold raised."
  @type flag :: %{flag: atom(), blocking: boolean(), detail: map()}

  @typedoc "The five figures this unit reconciles."
  @type figures :: %{
          balance: integer(),
          held: non_neg_integer(),
          promotional: non_neg_integer(),
          debt: non_neg_integer(),
          expired: non_neg_integer()
        }

  @typedoc "One wallet's outcome."
  @type report :: %{
          tenant_key: String.t(),
          checkpoint: String.t(),
          state: verdict(),
          reason: atom() | nil,
          flags: [flag()],
          ordering: :inserted_at | :seq | nil,
          rows: non_neg_integer(),
          lots: non_neg_integer(),
          allocations: non_neg_integer(),
          hold_links: non_neg_integer(),
          lock_ms: non_neg_integer() | nil,
          before: figures(),
          after: figures() | nil
        }

  @typedoc "What one run did."
  @type summary :: %{
          shadow: boolean(),
          wallets: non_neg_integer(),
          migrated: non_neg_integer(),
          blocked: non_neg_integer(),
          deferred: non_neg_integer(),
          skipped: non_neg_integer(),
          rows: non_neg_integer(),
          lots: non_neg_integer(),
          allocations: non_neg_integer(),
          duration_ms: non_neg_integer(),
          lock_ms_max: non_neg_integer(),
          cursor: String.t() | nil,
          resumed_from: String.t() | nil,
          selection: :scan | :tenants,
          unexamined: non_neg_integer() | nil,
          state: String.t(),
          reports: [report()]
        }

  @doc """
  The checkpoint name this unit uses for `tenant_key`.

  `"lot_migration:<tenant_key>"` when that is a legal
  `AuroraMeter.Operations` name, and `"lot_migration:sha256-<digest>"` when it
  is not. A tenant key is host supplied and may hold a space, an `@` or a
  slash; `AuroraMeter.Operations.pause/1` raises on anything outside
  `[a-z_]+:[A-Za-z0-9_.:-]+`, and a migration that raises halfway through a run
  because one customer's key has an `@` in it is not a migration
  (`open-findings.md` X221). The row's `counts` always carries the verbatim
  `tenant_key`, so a digested name is still resolvable.

  ## Examples

      iex> AuroraMeter.Credits.LotMigration.checkpoint_name("org_42")
      "lot_migration:org_42"

      iex> digest = :sha256 |> :crypto.hash("ops@example.com") |> Base.encode16(case: :lower)
      iex> AuroraMeter.Credits.LotMigration.checkpoint_name("ops@example.com") ==
      ...>   "lot_migration:sha256-" <> digest
      true

  """
  @spec checkpoint_name(String.t()) :: String.t()
  def checkpoint_name(tenant_key) when is_binary(tenant_key) do
    candidate = @prefix <> tenant_key

    if Regex.match?(@name_format, candidate) do
      candidate
    else
      digest = :sha256 |> :crypto.hash(tenant_key) |> Base.encode16(case: :lower)
      @prefix <> "sha256-" <> digest
    end
  end

  @doc """
  Whether a real cutover is refused, and why. `nil` when it is permitted.

  See the module documentation. The check is behavioural rather than a version
  number: it asks whether the lot-aware refund path
  (`AuroraMeter.Credits.reverse_lot/4`) exists, so it opened itself when that
  path shipped in build unit 06e and nothing else could have opened it. It
  answers `nil` from that release on, and the clause below is kept so a node
  running an older core still refuses rather than silently cutting wallets over.

  **What the probe cannot tell you**, and it is worth saying rather than
  leaving for someone to discover: `AuroraMeter.Credits` and this module ship in
  one package, so within a release the probe can only report that release's own
  state. It was written to order two build units during development, not to
  version-check a deployment, and a core that carried `reverse_lot/4` without
  repair unit R1's wallet-wide fix would have answered `nil` while
  `AuroraMeter.Credits.reverse/4` was still planning a refund as a debit. No
  such core was ever published: 06e and R1 are both unreleased at the time of
  writing, so `reverse_lot/4` and the lot-aware `reverse/4` reach Hex together.
  """
  @spec cutover_blocked() :: %{finding: String.t(), reason: String.t()} | nil
  def cutover_blocked do
    if cutover_wired?() do
      nil
    else
      %{
        finding: "X250",
        reason:
          "AuroraMeter.Credits.reverse/4 does not take the lot path yet, so a paid refund " <>
            "on a cut-over wallet would consume promotional lots in spend order and write " <>
            "nothing into `reversed`. Shadow runs and reports are unaffected."
      }
    end
  end

  @doc """
  Replays every wallet and, unless `shadow:` is false, reports without writing.

  #{NimbleOptions.docs(@schema)}

  Returns `{:ok, summary}`. The run continues past a wallet it cannot migrate:
  a blocked wallet is recorded with its reasons and the next one is attempted,
  which is why the summary rather than the return tuple is what says whether
  the run was clean.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) do
    opts = NimbleOptions.validate!(opts, @schema)
    repo = opts[:repo] || Config.repo()
    started = Clock.monotonic_ms()

    with :ok <- require_schema(repo),
         :ok <- permit(opts) do
      {:ok, execute(repo, opts, started)}
    end
  end

  @doc """
  What the last run left behind: the aggregate cursors and every wallet report.

  `:cursor` is how far the **real** migration has got, which is the one an
  operator means by "where has this got to". `:shadow_cursor` is how far the
  rehearsal has got. They are separate rows and neither steers the other
  (`open-findings.md` X427).

  Options: `:repo`, and `:limit` (default 200) on the wallet rows read back.
  """
  @spec status(keyword()) :: %{
          cursor: String.t() | nil,
          shadow_cursor: String.t() | nil,
          counts: map(),
          state: String.t() | nil,
          wallets: [map()]
        }
  def status(opts \\ []) do
    repo = opts[:repo] || Config.repo()
    aggregate = Checkpoints.get(@aggregate, repo: repo)
    shadow = Checkpoints.get(@aggregate_shadow, repo: repo)

    wallets =
      repo
      |> wallet_checkpoints(Keyword.get(opts, :limit, 200))
      |> Enum.map(fn row ->
        %{
          name: row.name,
          tenant_key: row.counts["tenant_key"],
          state: row.state,
          counts: row.counts,
          updated_at: row.updated_at
        }
      end)

    %{
      cursor: aggregate && aggregate.cursor["tenant_key"],
      shadow_cursor: shadow && shadow.cursor["tenant_key"],
      counts: (aggregate && aggregate.counts) || %{},
      state: aggregate && aggregate.state,
      wallets: wallets
    }
  end

  @doc """
  Folds `rows` into a book of lots, or says why it cannot.

  Pure: no repo, no clock, no configuration. `rows` are
  `AuroraMeter.Schema.CreditTransaction` structs for one wallet, in the order
  they are believed to have been committed. Exposed because it is the whole of
  the migration's judgement, and judgement is worth testing on its own.
  """
  @spec replay([CreditTransaction.t()], String.t()) :: {:ok, map()} | {:blocked, [flag()]}
  def replay(rows, tenant_key) do
    rows
    |> Enum.reduce_while(state(tenant_key), &fold/2)
    |> finish()
  end

  # -- the run loop -----------------------------------------------------------

  defp execute(repo, opts, started) do
    selection = if is_nil(opts[:tenant]), do: :scan, else: :tenants
    cursor = start_cursor(repo, opts)

    acc =
      repo
      |> tenants(opts, cursor)
      |> Enum.reduce(blank_summary(opts, cursor, selection), fn tenant_key, acc ->
        acc
        |> step_wallet(repo, tenant_key, opts)
        |> maybe_checkpoint(repo, opts)
      end)

    summary =
      acc
      |> Map.put(:unexamined, unexamined(repo, acc, cursor, opts))
      |> finalise(started)

    write_aggregate(repo, summary, opts)
    emit(summary)
    summary
  end

  # Where the scan starts, and the one case that must not resume.
  #
  # `--retry-blocked` is a sweep for wallets a previous run left behind, and
  # every one of them is **behind** the cursor by construction: the run that
  # declined a wallet carried on past it and stamped a later key. Resuming from
  # the cursor therefore scans the one stretch of the table that cannot contain
  # the wallets the flag exists for, so the documented remedy for a blocked
  # wallet ("settle the hold, then re-run with `--retry-blocked`") examined
  # nothing and exited 0. That is X427's defect wearing a different flag, and it
  # is `open-findings.md` X434.
  defp start_cursor(repo, opts) do
    if opts[:resume] and not opts[:retry_blocked], do: resume_cursor(repo, opts), else: nil
  end

  defp step_wallet(acc, repo, tenant_key, opts) do
    report = wallet(repo, tenant_key, opts)

    %{
      acc
      | wallets: acc.wallets + 1,
        migrated: acc.migrated + count(report, [:migrated]),
        blocked: acc.blocked + count(report, [:blocked]),
        deferred: acc.deferred + count(report, [:deferred]),
        skipped: acc.skipped + count(report, [:skipped]),
        rows: acc.rows + report.rows,
        lots: acc.lots + report.lots,
        allocations: acc.allocations + report.allocations,
        lock_ms_max: max(acc.lock_ms_max, report.lock_ms || 0),
        cursor: tenant_key,
        since_checkpoint: acc.since_checkpoint + 1,
        reports: [report | acc.reports]
    }
  end

  defp count(%{state: state}, states), do: if(state in states, do: 1, else: 0)

  defp maybe_checkpoint(acc, repo, opts) do
    if acc.since_checkpoint >= opts[:batch] do
      write_aggregate(repo, finalise(acc, nil), opts)
      %{acc | since_checkpoint: 0}
    else
      acc
    end
  end

  defp blank_summary(opts, cursor, selection) do
    %{
      shadow: opts[:shadow],
      wallets: 0,
      migrated: 0,
      blocked: 0,
      deferred: 0,
      skipped: 0,
      rows: 0,
      lots: 0,
      allocations: 0,
      lock_ms_max: 0,
      cursor: nil,
      resumed_from: cursor,
      selection: selection,
      unexamined: nil,
      since_checkpoint: 0,
      reports: []
    }
  end

  defp finalise(acc, started) do
    acc
    |> Map.drop([:since_checkpoint])
    |> Map.put(:reports, Enum.reverse(acc.reports))
    |> Map.put(:duration_ms, if(started, do: Clock.monotonic_ms() - started, else: 0))
    |> then(&Map.put(&1, :state, run_state(&1)))
  end

  # The three outcomes an operator has to be able to tell apart.
  #
  # `wallets 0` used to mean two opposite things and print the same summary:
  # "there was nothing to do", and "the cursor was past everything, so I looked
  # at nothing". The second is X427 and it exits 0 today. The state now says
  # which, and it says it from a number measured against the tables rather than
  # deduced from the cursor's promise, because the cursor's promise is the thing
  # that broke.
  defp run_state(%{blocked: blocked}) when blocked > 0, do: "complete_with_blocked"

  defp run_state(%{wallets: 0, unexamined: unexamined})
       when is_integer(unexamined) and unexamined > 0,
       do: "skipped_by_cursor"

  defp run_state(_summary), do: "complete"

  # -- one wallet -------------------------------------------------------------

  defp wallet(repo, tenant_key, opts) do
    name = checkpoint_name(tenant_key)
    report = decide(repo, tenant_key, name, opts)
    record(report, repo, opts)
  end

  defp decide(repo, tenant_key, name, opts) do
    row = balance_row(repo, tenant_key)

    cond do
      is_nil(row) ->
        skip(tenant_key, name, :no_balance_row, nil)

      row.lots_enabled_at ->
        migrated_already(repo, tenant_key, name, row, opts)

      Operations.paused?(name) and not opts[:retry_blocked] ->
        defer_report(tenant_key, name, row, :paused, 0)

      blocked_before?(repo, name) and not opts[:retry_blocked] ->
        still_blocked(tenant_key, name, row)

      true ->
        guarded(repo, tenant_key, name, row, opts)
    end
  end

  # **A wallet a previous run could not migrate is still not migrated**, and a
  # run that reported it as merely skipped would exit zero with money left on
  # the legacy writer. The replay is not repeated, because nothing about the
  # wallet has changed and the work is not free; the verdict is, so the run's
  # exit status and its summary both still name it. `--retry-blocked` is what
  # asks for the work to be done again, after the data has been understood.
  #
  # Its reasons are not rewritten either: the checkpoint row still carries the
  # flags the run that decided them wrote, which `status/1` reads back.
  defp still_blocked(tenant_key, name, row) do
    tenant_key
    |> base_report(name, row)
    |> Map.merge(%{state: :blocked, reason: :blocked_before})
  end

  # A deferred wallet is work the operator chose to put off, so it does not
  # fail the run; a blocked one is work nobody has decided about yet, so it
  # does.
  defp paused_before?(%{state: :deferred, reason: :paused}), do: true
  defp paused_before?(_report), do: false

  # A wallet that raises for any reason, `AuroraMeter.Credits.ConservationError`
  # included, is one wallet's problem. It is recorded with the exception and
  # the run goes on to the next, because a fleet-wide migration that stops on
  # the first odd history leaves every wallet behind it unmigrated and tells
  # the operator about only one of them.
  defp guarded(repo, tenant_key, name, row, opts) do
    attempt(repo, tenant_key, name, row, opts)
  rescue
    error ->
      Logger.warning(
        "AuroraMeter.Credits.LotMigration: #{inspect(tenant_key)} raised " <>
          Exception.format(:error, error, __STACKTRACE__) <>
          " The wallet is untouched and reported blocked; the run continues."
      )

      blocked(tenant_key, name, [flag(:exception, %{message: Exception.message(error)})], 0, row)
  end

  defp attempt(repo, tenant_key, name, row, opts) do
    rows = count_rows(repo, tenant_key)

    if rows > opts[:max_rows] do
      defer_report(tenant_key, name, row, :too_large, rows)
    else
      cutover(repo, tenant_key, name, ledger_rows(repo, tenant_key), opts)
    end
  end

  defp cutover(repo, tenant_key, name, rows, opts) do
    high = watermark(rows)

    case replay_ordered(rows, tenant_key) do
      {:ok, book, ordering} ->
        lock_phase(repo, tenant_key, name, {rows, book, ordering, high}, opts)

      {:blocked, flags} ->
        blocked(tenant_key, name, flags, length(rows), nil)
    end
  end

  # The lock phase is one transaction: the balance row `FOR UPDATE` first,
  # which is the order `architecture-map.md` 7.3 fixes for every ledger write
  # and is therefore an order this can never deadlock against a live one on;
  # then the tail, the verify, the writes, and the conservation check last.
  defp lock_phase(repo, tenant_key, name, snapshot, opts) do
    started = Clock.monotonic_ms()

    result =
      repo.transaction(fn ->
        locked = lock_row(repo, tenant_key)

        cond do
          is_nil(locked) -> {:gone, nil}
          locked.lots_enabled_at -> {:raced, locked}
          true -> committed(repo, tenant_key, snapshot, locked, opts)
        end
      end)

    finish_lock(result, tenant_key, name, snapshot, Clock.monotonic_ms() - started)
  end

  defp committed(repo, tenant_key, {rows, book, ordering, high}, locked, opts) do
    tail = tail_rows(repo, tenant_key, high)

    cond do
      length(tail) > opts[:max_tail] -> {:busy, locked}
      tail == [] -> verify(repo, book, ordering, locked, length(rows), opts)
      true -> refold(repo, tenant_key, rows ++ tail, locked, opts)
    end
  end

  defp refold(repo, tenant_key, rows, locked, opts) do
    case replay_ordered(rows, tenant_key) do
      {:ok, book, ordering} -> verify(repo, book, ordering, locked, length(rows), opts)
      {:blocked, flags} -> {:blocked, flags, length(rows), locked}
    end
  end

  defp verify(repo, book, ordering, locked, rows, opts) do
    projected = Allocator.projection(book.book, book.debt)

    case mismatch(projected, locked) do
      [] ->
        reconciled(repo, book, ordering, locked, rows, opts[:shadow])

      deltas ->
        {:blocked, [flag(:projection_mismatch, Map.new(deltas)) | book.flags], rows, locked}
    end
  end

  defp reconciled(_repo, book, ordering, locked, rows, true),
    do: {:shadow_ok, book, ordering, locked, rows}

  defp reconciled(repo, book, ordering, locked, rows, false),
    do: {:written, write!(repo, book, locked), book, ordering, locked, rows}

  defp mismatch(projected, locked) do
    for {key, actual} <- [
          balance: locked.balance,
          held: locked.held,
          promotional: locked.promotional
        ],
        Map.fetch!(projected, key) != actual,
        do: {key, %{replayed: Map.fetch!(projected, key), row: actual}}
  end

  defp finish_lock({:ok, {:gone, _row}}, tenant_key, name, _snapshot, _ms),
    do: skip(tenant_key, name, :no_balance_row, nil)

  defp finish_lock({:ok, {:raced, locked}}, tenant_key, name, _snapshot, _ms),
    do: skip(tenant_key, name, :already_migrated, locked)

  defp finish_lock({:ok, {:busy, locked}}, tenant_key, name, {rows, _b, _o, _h}, ms) do
    tenant_key
    |> defer_report(name, locked, :too_busy, length(rows))
    |> Map.put(:lock_ms, ms)
  end

  defp finish_lock({:ok, {:blocked, flags, rows, locked}}, tenant_key, name, _snapshot, ms) do
    tenant_key
    |> blocked(name, flags, rows, locked)
    |> Map.put(:lock_ms, ms)
  end

  defp finish_lock({:ok, {:shadow_ok, book, order, locked, rows}}, key, name, _snapshot, ms) do
    key
    |> succeeded(name, :shadow_ok, book, order, locked, rows)
    |> Map.put(:lock_ms, ms)
  end

  defp finish_lock({:ok, {:written, after_row, book, order, locked, rows}}, key, name, _s, ms) do
    key
    |> succeeded(name, :migrated, book, order, locked, rows)
    |> Map.put(:lock_ms, ms)
    |> Map.put(:after, figures(after_row))
  end

  defp finish_lock({:error, reason}, tenant_key, name, {rows, _b, _o, _h}, ms) do
    tenant_key
    |> blocked(name, [flag(:exception, %{reason: inspect(reason)})], length(rows), nil)
    |> Map.put(:lock_ms, ms)
  end

  # -- the writes -------------------------------------------------------------

  defp write!(repo, book, locked) do
    now = Clock.db_now()
    insert_lots!(repo, book, now)
    insert_allocations!(repo, book)
    link_holds!(repo, book)

    projected = Allocator.projection(book.book, book.debt)

    updated =
      locked
      |> Ecto.Changeset.change(
        debt: book.debt,
        expired: projected.expired,
        lots_enabled_at: DateTime.truncate(now, :second)
      )
      |> repo.update!()

    # Last statement before commit, and it is a re-read rather than a
    # recomputation: it asks the database what the lots now say and compares
    # that with the row that was just written.
    Allocator.check!(repo, updated, :lot_migration, nil)
  end

  defp insert_lots!(_repo, %{lots: []}, _now), do: :ok

  defp insert_lots!(repo, book, now) do
    final = Map.new(book.book, &{&1.id, &1})

    # In fold order, so the identity `seq` the database assigns agrees with the
    # provisional order the fold decided the spend order with.
    book.lots
    |> Enum.map(&lot_row(&1, Map.fetch!(final, &1.id), now))
    |> Enum.chunk_every(500)
    |> Enum.each(&repo.insert_all(CreditLot, &1))
  end

  defp lot_row(lot, final, now) do
    quantities = Map.take(final, @quantities)

    Map.merge(quantities, %{
      id: lot.id,
      tenant_key: lot.tenant_key,
      grant_transaction_id: lot.grant_transaction_id,
      reference: lot.reference,
      category: lot.category,
      amount: lot.amount,
      granted_at: lot.granted_at,
      expires_at: lot.expires_at,
      source: lot.source,
      state: CreditLot.state_for(Map.put(quantities, :amount, lot.amount)),
      inserted_at: now,
      updated_at: now
    })
  end

  defp insert_allocations!(_repo, %{allocations: []}), do: :ok

  defp insert_allocations!(repo, book) do
    book.allocations
    |> Enum.map(&Map.put(&1, :id, Ecto.UUID.generate()))
    |> Enum.chunk_every(500)
    |> Enum.each(&repo.insert_all(CreditAllocation, &1))
  end

  defp link_holds!(_repo, %{hold_links: []}), do: :ok

  defp link_holds!(repo, book) do
    {ids, holds} = Enum.unzip(book.hold_links)

    # One statement, and `IS NULL` makes a second run over the same rows a
    # no-op. `updated_at` is deliberately left null: the row was not changed by
    # a writer, it was given a column that had never been filled in.
    repo.query!(
      """
      UPDATE aurora_meter_credit_transactions AS t
         SET hold_transaction_id = v.hold_id
        FROM (SELECT unnest($1::uuid[]) AS id, unnest($2::uuid[]) AS hold_id) AS v
       WHERE t.id = v.id AND t.hold_transaction_id IS NULL
      """,
      [Enum.map(ids, &uuid!/1), Enum.map(holds, &uuid!/1)]
    )

    :ok
  end

  defp uuid!(value) do
    {:ok, dumped} = Ecto.UUID.dump(value)
    dumped
  end

  # -- reports ----------------------------------------------------------------

  defp skip(tenant_key, name, reason, row) do
    tenant_key
    |> base_report(name, row)
    |> Map.merge(%{state: :skipped, reason: reason})
  end

  defp migrated_already(repo, tenant_key, name, row, opts) do
    if opts[:report_only] do
      report_only(repo, tenant_key, name, row)
    else
      skip(tenant_key, name, :already_migrated, row)
    end
  end

  defp report_only(repo, tenant_key, name, row) do
    lots = repo.aggregate(from(l in CreditLot, where: l.tenant_key == ^tenant_key), :count, :id)

    allocations =
      repo.aggregate(from(a in CreditAllocation, where: a.tenant_key == ^tenant_key), :count, :id)

    tenant_key
    |> base_report(name, row)
    |> Map.merge(%{
      state: :skipped,
      reason: :already_migrated,
      lots: lots,
      allocations: allocations,
      after: figures(row)
    })
  end

  defp defer_report(tenant_key, name, row, reason, rows) do
    tenant_key
    |> base_report(name, row)
    |> Map.merge(%{state: :deferred, reason: reason, rows: rows})
  end

  defp blocked(tenant_key, name, flags, rows, row) do
    tenant_key
    |> base_report(name, row)
    |> Map.merge(%{state: :blocked, reason: :ambiguous, flags: flags, rows: rows})
  end

  defp succeeded(tenant_key, name, state, book, ordering, locked, rows) do
    tenant_key
    |> base_report(name, locked)
    |> Map.merge(%{
      state: state,
      flags: book.flags,
      ordering: ordering,
      rows: rows,
      lots: length(book.lots),
      allocations: length(book.allocations),
      hold_links: length(book.hold_links)
    })
  end

  defp base_report(tenant_key, name, row) do
    %{
      tenant_key: tenant_key,
      checkpoint: name,
      state: :skipped,
      reason: nil,
      flags: [],
      ordering: nil,
      rows: 0,
      lots: 0,
      allocations: 0,
      hold_links: 0,
      lock_ms: nil,
      before: figures(row),
      after: nil
    }
  end

  defp figures(nil), do: %{balance: 0, held: 0, promotional: 0, debt: 0, expired: 0}
  defp figures(row), do: Map.take(row, [:balance, :held, :promotional, :debt, :expired])

  # The per-wallet report is written after the wallet's own transaction has
  # ended, in a statement of its own, so a block never loses its reason to the
  # rollback that produced it.
  defp record(report, repo, opts) do
    if silent?(report, opts) do
      report
    else
      Checkpoints.put(
        report.checkpoint,
        %{"tenant_key" => report.tenant_key},
        counts(report),
        checkpoint_state(report, opts),
        repo: repo
      )

      pause_if_deferred(report, opts)
      report
    end
  end

  # Two verdicts write nothing: a wallet this run did not look at, and a wallet
  # whose verdict a previous run already wrote. Overwriting the second would
  # replace its reasons with "it was blocked before", which is the one thing an
  # operator reading the row does not need to be told.
  defp silent?(%{reason: :blocked_before}, _opts), do: true
  defp silent?(report, opts), do: paused_before?(report) or skipped_quietly?(report, opts)

  defp skipped_quietly?(%{state: :skipped}, opts), do: not opts[:report_only]
  defp skipped_quietly?(_report, _opts), do: false

  # A wallet too large for this run's bound is paused on 05c's own operator
  # surface, so `AuroraMeter.Operations.paused?/1` answers for it and a later
  # run does not silently pick it up again with a bound the operator did not
  # choose. It runs after the report is written, because `pause/1` leaves
  # `cursor` and `counts` alone and would otherwise be overwritten by them.
  # Never in shadow: a shadow run must leave nothing for an operator to undo.
  defp pause_if_deferred(%{state: :deferred, reason: :too_large} = report, opts) do
    unless opts[:shadow], do: Operations.pause(report.checkpoint)
    :ok
  end

  defp pause_if_deferred(_report, _opts), do: :ok

  defp checkpoint_state(%{state: :blocked}, opts),
    do: if(opts[:shadow], do: "shadow_blocked", else: "blocked")

  # `--report-only` re-reports a wallet that is already migrated. Writing
  # "skipped" over its row would replace the true verdict with a description of
  # this run's behaviour, which is the wrong half of the story for the row an
  # operator reads.
  defp checkpoint_state(%{state: :skipped, reason: :already_migrated}, _opts), do: "migrated"

  defp checkpoint_state(%{state: state}, _opts), do: Atom.to_string(state)

  defp counts(report) do
    %{
      "tenant_key" => report.tenant_key,
      "reason" => report.reason && Atom.to_string(report.reason),
      "ordering" => report.ordering && Atom.to_string(report.ordering),
      "rows" => report.rows,
      "lots" => report.lots,
      "allocations" => report.allocations,
      "hold_links" => report.hold_links,
      "lock_ms" => report.lock_ms,
      "before" => stringify(report.before),
      "after" => report.after && stringify(report.after),
      "flags" => Enum.map(report.flags, &stringify_flag/1)
    }
  end

  defp stringify(figures),
    do: Map.new(figures, fn {key, value} -> {Atom.to_string(key), value} end)

  defp stringify_flag(%{flag: name, blocking: blocking, detail: detail}) do
    %{"flag" => Atom.to_string(name), "blocking" => blocking, "detail" => inspect(detail)}
  end

  defp write_aggregate(repo, summary, opts) do
    name = aggregate(summary.shadow)

    Checkpoints.put(
      name,
      %{"tenant_key" => advance(repo, name, summary, opts)},
      %{
        "wallets" => summary.wallets,
        "migrated" => summary.migrated,
        "blocked" => summary.blocked,
        "deferred" => summary.deferred,
        "skipped" => summary.skipped,
        "rows" => summary.rows,
        "lots" => summary.lots,
        "allocations" => summary.allocations,
        "lock_ms_max" => summary.lock_ms_max,
        "shadow" => summary.shadow,
        "resumed_from" => summary.resumed_from,
        "unexamined" => summary.unexamined
      },
      summary.state,
      repo: repo
    )
  end

  # The mode's own aggregate row. See the comment on `@aggregate_shadow`.
  defp aggregate(true), do: @aggregate_shadow
  defp aggregate(false), do: @aggregate

  # **Progress is never un-made by a run that made none.**
  #
  # This was the second half of X427 and the half that made the symptom
  # alternate. `summary.cursor` is nil when the run stepped no wallet, and
  # writing that nil over the row erased the resume point, so the run after a
  # zero-wallet run started from the beginning again and the outcome depended on
  # how many times the task had been invoked. It also means an interrupted real
  # run's resume point could be destroyed by any later run that happened to
  # examine nothing, which is the thing build unit 11b needs to survive.
  #
  # A `--retry-blocked` sweep does not move it either: that run starts from the
  # beginning by design (`start_cursor/2`), so letting it stamp its own last
  # wallet would drag the forward pass's cursor backwards.
  defp advance(repo, name, summary, opts) do
    if opts[:retry_blocked] or is_nil(summary.cursor),
      do: existing_cursor(repo, name),
      else: summary.cursor
  end

  defp existing_cursor(repo, name) do
    case Checkpoints.get(name, repo: repo) do
      %{cursor: %{"tenant_key" => key}} when is_binary(key) -> key
      _absent_or_null -> nil
    end
  end

  defp emit(summary) do
    :telemetry.execute(
      [:aurora_meter, :credits, :lot_migration],
      %{
        wallets: summary.wallets,
        migrated: summary.migrated,
        blocked: summary.blocked,
        deferred: summary.deferred,
        rows: summary.rows,
        duration_ms: summary.duration_ms
      },
      %{shadow: summary.shadow, state: summary.state}
    )
  end

  # -- gates and queries ------------------------------------------------------

  defp require_schema(repo) do
    case Checkpoints.get("schema:core", repo: repo) do
      %{cursor: %{"version" => version}} when is_integer(version) and version >= 9 -> :ok
      _absent_or_older -> schema_fallback(repo)
    end
  end

  # The marker's shape belongs to 03a and a database migrated by a host's own
  # file may predate it, so when it does not answer, ask the table itself:
  # `lots_enabled_at` is the column version 9 adds and the one this task writes.
  defp schema_fallback(repo) do
    %{rows: [[count]]} =
      repo.query!(
        """
        SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'aurora_meter_credit_balances' AND column_name = 'lots_enabled_at'
        """,
        []
      )

    if count == 1, do: :ok, else: {:error, :schema_below_version_9}
  end

  defp permit(opts) do
    cond do
      opts[:shadow] -> :ok
      not opts[:allow_cutover] -> {:error, :cutover_not_requested}
      true -> permit_cutover(cutover_blocked())
    end
  end

  defp permit_cutover(nil), do: :ok
  defp permit_cutover(reason), do: {:error, {:cutover_blocked, reason}}

  # `function_exported?/3` rather than a version number: the gate is the
  # presence of the lot-aware refund path itself, so it opens when that path
  # ships and nothing else can open it. The second clause is the maintainer
  # suite's door, under the harness's own OTP application, which this package's
  # configuration never reads and a host has no reason to set.
  # `Code.ensure_loaded?/1` before `function_exported?/3`, and it is not a
  # formality. `function_exported?/3` answers **false for a module that is
  # simply not loaded yet**, so in a host running
  # `mix aurora_meter.credits.migrate_lots --no-shadow` this probe said "the
  # lot-aware refund path does not exist" about a path that does, and every
  # cutover in every install was refused with a reason that had been repaired.
  # Measured in a fixture host before the fix: module_loaded false,
  # function_exported? false, cutover_blocked true; after `Code.ensure_loaded`,
  # all three the other way round (build unit 11a, `open-findings.md` X426).
  #
  # Nothing in the suite could see it, because all three lot-cutover test files
  # set `:allow_lot_cutover`, and `or` short-circuits: the branch below the
  # escape hatch had never been evaluated by any test.
  defp cutover_wired? do
    Application.get_env(:aurora_meter_test, :allow_lot_cutover, false) or
      (Code.ensure_loaded?(AuroraMeter.Credits) and
         function_exported?(AuroraMeter.Credits, :reverse_lot, 4))
  end

  defp balance_row(repo, tenant_key),
    do: repo.one(from(b in CreditBalance, where: b.tenant_key == ^tenant_key))

  defp lock_row(repo, tenant_key),
    do: repo.one(from(b in CreditBalance, where: b.tenant_key == ^tenant_key, lock: "FOR UPDATE"))

  defp count_rows(repo, tenant_key),
    do:
      repo.aggregate(
        from(t in CreditTransaction, where: t.tenant_key == ^tenant_key),
        :count,
        :id
      )

  defp ledger_rows(repo, tenant_key) do
    repo.all(
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant_key,
        order_by: [asc: t.inserted_at, asc: t.id]
      )
    )
  end

  # `seq` is not a sound **order** for a pre-version-9 row, and it is a sound
  # **watermark**: a row committed after this read is written by the current
  # code and therefore carries an identity above every existing one. So the
  # tail read is exact even though the fold cannot trust the same column to
  # order history by.
  defp watermark([]), do: 0
  defp watermark(rows), do: rows |> Enum.map(& &1.seq) |> Enum.max()

  defp tail_rows(repo, tenant_key, high) do
    repo.all(
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant_key and t.seq > ^high,
        order_by: [asc: t.seq]
      )
    )
  end

  defp tenants(repo, opts, cursor) do
    case opts[:tenant] do
      nil -> scan(repo, cursor, opts[:max_wallets])
      list when is_list(list) -> Enum.map(list, &Tenant.to_key/1)
      tenant -> [Tenant.to_key(tenant)]
    end
  end

  defp scan(repo, cursor, limit) do
    from(b in CreditBalance, order_by: [asc: b.tenant_key], select: b.tenant_key, limit: ^limit)
    |> scan_after(cursor)
    |> repo.all()
  end

  defp scan_after(query, nil), do: query
  defp scan_after(query, cursor), do: where(query, [b], b.tenant_key > ^cursor)

  defp resume_cursor(repo, opts), do: existing_cursor(repo, aggregate(opts[:shadow]))

  # How many wallets are still on the legacy writer that this run did not
  # examine and that no run of this mode has recorded a verdict for.
  #
  # **Measured against the tables, not deduced from the cursor.** Once the
  # cursors are separated this number should always be zero, because a mode's
  # cursor only ever advances over wallets that mode examined. That is exactly
  # why it is counted rather than asserted: a report that derives "nothing was
  # skipped" from the same invariant that skipped everything cannot notice when
  # that invariant breaks again, and this one broke in production
  # (`open-findings.md` X427, and X153 on rules nothing enforces). Put the
  # single shared cursor back and this number is sixteen.
  defp unexamined(repo, summary, cursor, opts),
    do: scan_unexamined(repo, summary, cursor, opts, opts[:tenant])

  # An explicit `--tenant` list is the operator naming the wallets they want, so
  # "what else is out there" is not a number this run is entitled to call
  # skipped. `nil` reads as "not applicable" everywhere downstream.
  defp scan_unexamined(_repo, _summary, _cursor, _opts, tenant) when not is_nil(tenant), do: nil

  defp scan_unexamined(repo, summary, cursor, opts, nil),
    do: behind(repo, cursor, opts) + ahead(repo, summary.cursor || cursor)

  # Legacy wallets the resume jumped over that carry no verdict from this mode.
  defp behind(_repo, nil, _opts), do: 0

  defp behind(repo, cursor, opts) do
    settled = settled_keys(repo, opts[:shadow])

    legacy =
      repo.all(
        from(b in CreditBalance,
          where: is_nil(b.lots_enabled_at) and b.tenant_key <= ^cursor,
          select: b.tenant_key,
          limit: ^opts[:max_wallets]
        )
      )

    Enum.count(legacy, &(not MapSet.member?(settled, &1)))
  end

  # Legacy wallets past the far end of what this run examined, which is what
  # `--max-wallets` leaves for the next run. After a run that reached the end of
  # the table this is zero, including when wallets were declined: a declined
  # wallet is behind the cursor, not ahead of it.
  defp ahead(repo, nil),
    do:
      repo.aggregate(
        from(b in CreditBalance, where: is_nil(b.lots_enabled_at)),
        :count,
        :tenant_key
      )

  defp ahead(repo, key),
    do:
      repo.aggregate(
        from(b in CreditBalance, where: is_nil(b.lots_enabled_at) and b.tenant_key > ^key),
        :count,
        :tenant_key
      )

  defp settled_keys(repo, shadow?) do
    states = if shadow?, do: @settled_shadow, else: @settled_real

    repo
    |> wallet_checkpoints(:all)
    |> Enum.filter(&(&1.state in states))
    |> MapSet.new(& &1.counts["tenant_key"])
  end

  defp blocked_before?(repo, name) do
    case Checkpoints.get(name, repo: repo) do
      %{state: state} -> state in ["blocked", "shadow_blocked"]
      nil -> false
    end
  end

  defp wallet_checkpoints(repo, :all) do
    [repo: repo]
    |> Checkpoints.all()
    |> Enum.filter(&String.starts_with?(&1.name, @prefix))
  end

  defp wallet_checkpoints(repo, limit), do: repo |> wallet_checkpoints(:all) |> Enum.take(limit)

  # -- ordering ---------------------------------------------------------------

  defp replay_ordered(rows, tenant_key) do
    case replay(rows, tenant_key) do
      {:ok, book} -> {:ok, book, :inserted_at}
      {:blocked, flags} -> maybe_retry(rows, tenant_key, flags)
    end
  end

  defp maybe_retry(rows, tenant_key, flags) do
    by_seq = Enum.sort_by(rows, & &1.seq)

    if order_sensitive?(flags) and Enum.map(by_seq, & &1.id) != Enum.map(rows, & &1.id) do
      retry_ordered(by_seq, tenant_key, flags)
    else
      {:blocked, flags}
    end
  end

  defp retry_ordered(by_seq, tenant_key, first) do
    case replay(by_seq, tenant_key) do
      {:ok, book} -> {:ok, book, :seq}
      {:blocked, second} -> {:blocked, [out_of_order(first, second) | first ++ second]}
    end
  end

  defp out_of_order(first, second) do
    flag(:history_out_of_order, %{
      inserted_at_order: Enum.map(first, & &1.flag),
      seq_order: Enum.map(second, & &1.flag)
    })
  end

  defp order_sensitive?(flags), do: Enum.any?(flags, &(&1.flag in @order_sensitive))

  # -- the fold ---------------------------------------------------------------

  defp state(tenant_key) do
    %{
      tenant_key: tenant_key,
      book: [],
      lots: [],
      categories: %{},
      by_grant: %{},
      by_reference: %{},
      holds: %{},
      allocations: [],
      hold_links: [],
      flags: [],
      debt: 0,
      balance: 0,
      held: 0,
      promotional: 0,
      seq: 0
    }
  end

  defp fold(row, acc) do
    case step(acc, row) do
      {:ok, acc, plan} -> apply_plan(acc, row, plan)
      {:flag, name, detail} -> {:halt, {:blocked, [flag(name, detail) | acc.flags]}}
    end
  end

  defp finish({:blocked, flags}), do: {:blocked, Enum.reverse(flags)}

  defp finish(acc) do
    projected = Allocator.projection(acc.book, acc.debt)
    running = %{balance: acc.balance, held: acc.held, promotional: acc.promotional}

    drift =
      for {key, value} <- running,
          Map.fetch!(projected, key) != value,
          do: {key, %{running: value, book: Map.fetch!(projected, key)}}

    if drift == [] do
      {:ok, acc |> reserved_note() |> settled_book()}
    else
      {:blocked, Enum.reverse([flag(:internal_projection_drift, Map.new(drift)) | acc.flags])}
    end
  end

  # **Invariant I12, named in the report rather than acted on.** A hold that is
  # still open at cutover against a lot that carries an `expires_at` is the one
  # wallet shape where the money moves differently after the migration than it
  # would have before: when that hold is released, whatever it still holds on a
  # lot past its expiry is written off instead of handed back. Nothing moves
  # now, so this is informational; the report is how an operator learns which
  # wallets are in that position before the difference appears.
  #
  # Whether the expiry has actually passed is deliberately left to the reader:
  # deciding it here would need a clock, and this fold does not read one.
  defp reserved_note(acc) do
    Enum.reduce(acc.book, acc, fn lot, inner ->
      if lot.reserved > 0 and not is_nil(lot.expires_at) do
        note(inner, :reserved_on_expiring_lot, %{
          lot_reference: lot_reference(acc, lot.id),
          reserved: lot.reserved,
          expires_at: lot.expires_at
        })
      else
        inner
      end
    end)
  end

  defp lot_reference(acc, lot_id) do
    case Enum.find(acc.lots, &(&1.id == lot_id)) do
      nil -> nil
      lot -> lot.reference
    end
  end

  defp settled_book(acc) do
    %{
      acc
      | allocations: Enum.reverse(acc.allocations),
        lots: Enum.reverse(acc.lots),
        hold_links: Enum.reverse(acc.hold_links),
        flags: Enum.reverse(acc.flags)
    }
  end

  defp flag(name, detail), do: %{flag: name, blocking: name in @blocking, detail: detail}

  defp note(acc, name, detail), do: %{acc | flags: [flag(name, detail) | acc.flags]}

  # -- one row ----------------------------------------------------------------

  # **Both reversal shapes route here, and the fallthrough below is why that
  # sentence is load bearing** (finding X266). A reversal written before schema
  # version 9 is `kind: :debit, category: :reversal`; one written after build
  # unit 06c is `kind: :reverse`. Rows already in the log cannot change, so the
  # old clause is permanent; new rows carry the new kind, so the new clause is
  # required. Without it every wallet that had ever taken a refund would fall
  # through to `:unsupported_row`, which is **blocking**, and no test would have
  # said so: the migration would simply have reached fewer wallets, on top of
  # the two thirds X263 had just measured.
  #
  # `Schema.CreditTransaction.reversal?/1` is the predicate, and the two clauses
  # below are the pattern-matching form of it; the guard version is used rather
  # than the function so the dispatch stays one `case` in the BEAM.
  defp step(acc, %{kind: :grant} = row), do: grant(acc, row)
  defp step(acc, %{kind: :hold} = row), do: hold(acc, row)
  defp step(acc, %{kind: :settle} = row), do: close(acc, row, :settle)
  defp step(acc, %{kind: :release} = row), do: close(acc, row, :release)
  defp step(acc, %{kind: :reverse} = row), do: reversal(acc, row)
  defp step(acc, %{kind: :debit, category: :reversal} = row), do: reversal(acc, row)
  defp step(acc, %{kind: :debit} = row), do: debit(acc, row)
  defp step(acc, %{kind: :expire} = row), do: expire(acc, row)

  defp step(_acc, row),
    do: {:flag, :unsupported_row, %{kind: row.kind, category: row.category, id: row.id}}

  defp grant(acc, %{category: category} = row)
       when category in [:paid, :promotional, :adjustment] do
    case source_for(row) do
      {:ok, source} -> granted(acc, row, source)
      {:error, name, detail} -> {:flag, name, detail}
    end
  end

  defp grant(_acc, row),
    do: {:flag, :unsupported_row, %{kind: :grant, category: row.category, id: row.id}}

  defp granted(acc, row, source) do
    lot = new_lot(acc, row, source)
    {:ok, plan} = Allocator.plan(acc.book, {:grant, lot, acc.debt})
    {:ok, remember_lot(acc, lot), plan}
  end

  # **The lot carries the grant row's own amount, not the amount
  # `AuroraMeter.Credits.Promotions` attributes to it.** The two agree, by a
  # route worth writing down: `Promotions` gives a grant
  # `min(amount, max(balance_after - running_total, 0))`, which is less than
  # the amount exactly when the grant landed on a negative balance; the lot
  # model gives the lot its whole amount and then repays the debt out of it,
  # which leaves the same value spendable. Recording the amount is also the
  # only version that keeps the balance delta equal to the row's, which is what
  # the chain check compares.
  defp new_lot(acc, row, source) do
    %{
      id: Ecto.UUID.generate(),
      tenant_key: acc.tenant_key,
      grant_transaction_id: row.id,
      reference: row.reference,
      category: row.category,
      amount: row.amount,
      expires_at: row.expires_at,
      granted_at: row.inserted_at,
      seq: acc.seq + 1,
      source: source
    }
  end

  defp remember_lot(acc, lot) do
    %{
      acc
      | lots: [lot | acc.lots],
        categories: Map.put(acc.categories, lot.id, lot.category),
        by_grant: Map.put(acc.by_grant, lot.grant_transaction_id, lot.id),
        by_reference: Map.put_new(acc.by_reference, lot.reference, lot.id),
        seq: acc.seq + 1
    }
  end

  defp hold(acc, row) do
    case Allocator.plan(acc.book, {:hold, row.held_delta, @legacy_now, acc.debt}) do
      {:ok, plan} -> reserved(acc, row, plan)
      {:error, reason} -> {:flag, :hold_unbacked, hold_detail(acc, row, reason)}
    end
  end

  defp hold_detail(acc, row, reason) do
    %{reference: row.reference, amount: row.held_delta, reason: reason, debt: acc.debt}
  end

  defp reserved(acc, row, plan) do
    reservations =
      plan.movements
      |> Enum.filter(&(&1.to == :reserved))
      |> Enum.map(&{&1.lot_id, &1.amount})

    holds = Map.put(acc.holds, row.reference, %{txn_id: row.id, reservations: reservations})
    {:ok, %{acc | holds: holds}, plan}
  end

  defp close(acc, row, kind) do
    case Map.fetch(acc.holds, row.reference) do
      {:ok, held} -> close_with(acc, row, kind, held)
      :error -> {:flag, orphan(kind), %{reference: row.reference, id: row.id}}
    end
  end

  defp orphan(:settle), do: :orphan_settle
  defp orphan(:release), do: :orphan_release

  defp close_with(acc, row, kind, held) do
    {:ok, plan} = Allocator.plan(acc.book, request(kind, acc, row, held))

    acc = %{
      acc
      | holds: Map.delete(acc.holds, row.reference),
        hold_links: [{row.id, held.txn_id} | acc.hold_links]
    }

    {:ok, acc, plan}
  end

  defp request(:settle, acc, row, held),
    do: {:settle, held.reservations, settled(row), @legacy_now, acc.debt}

  defp request(:release, acc, _row, held),
    do: {:release, held.reservations, @legacy_now, acc.debt}

  defp settled(%{settled_amount: amount}) when is_integer(amount), do: amount
  defp settled(%{amount: amount}), do: -amount

  # **A debit is replayed as `allow_negative`, always.** The legacy ledger took
  # the policy decision years ago; refusing the row now would not undo the
  # spend, it would only stop the wallet migrating. What the fold owes is the
  # **arithmetic**, and the part of a spend that no lot can fund is debt, which
  # is the lot model's record of exactly the negative balance the legacy row
  # carries. The chain check on `balance_after` proves the two agree, and a
  # policy refusal proves nothing.
  defp debit(acc, row) do
    {:ok, plan} = Allocator.plan(acc.book, {:debit, -row.amount, @legacy_now, true, 0, acc.debt})
    {:ok, acc, plan}
  end

  defp reversal(acc, row) do
    amount = -row.amount

    case payment_intent(acc, row) do
      nil ->
        {:flag, :reversal_unattributed, %{reference: row.reference, id: row.id, resolved: :none}}

      intent ->
        reverse_against(acc, row, intent, amount)
    end
  end

  # `acc.debt` is passed because the planner's `{:reverse, ...}` now repays the
  # debt it creates out of the wallet's remaining non-promotional availability
  # (finding X262). The fold has to hand it the same debt it hands every other
  # request, or the replay would compute a different book from the runtime for
  # the same history.
  defp reverse_against(acc, row, intent, amount) do
    case Allocator.plan(acc.book, {:reverse, intent, amount, @legacy_now, acc.debt}) do
      {:ok, plan} ->
        check_reversal(acc, row, intent, amount, plan)

      {:error, :no_matching_lot} ->
        {:flag, :reversal_unattributed,
         %{reference: row.reference, payment_intent_id: intent, amount: amount}}
    end
  end

  # **`to == :reversed`, not every movement** (X262). Since the planner repays
  # the debt a reversal creates, a plan can carry `consume` movements that are
  # not part of the reversal at all. Summing every movement would let a
  # repayment of X hide a reversal that fell X short of the row, which is
  # exactly the shortfall `reversal_exceeds_lots` exists to catch: a legacy row
  # that took back more than its lots can account for is a wallet whose
  # provenance the fold must not invent.
  defp check_reversal(acc, row, intent, amount, plan) do
    moved =
      plan.movements
      |> Enum.filter(&(&1.to == :reversed))
      |> Enum.map(& &1.amount)
      |> Enum.sum()

    cond do
      moved < amount ->
        {:flag, :reversal_exceeds_lots,
         %{reference: row.reference, payment_intent_id: intent, wanted: amount, took: moved}}

      Enum.any?(plan.movements, &(&1.from == :reserved)) ->
        {:flag, :reversal_took_reserved,
         %{reference: row.reference, payment_intent_id: intent, amount: amount}}

      true ->
        {:ok, acc, plan}
    end
  end

  # An `expire` row carries the amount the legacy sweep decided on, which was
  # clamped by the wallet's spendable balance and could therefore be a fraction
  # of the grant. The planner's `:expire` takes a lot's whole `available`,
  # which is right for the sweep and wrong for a replay, so this is the one
  # place the fold builds its own movement. It is still checked by the chain,
  # by the lot CHECK constraints and by the conservation check.
  defp expire(acc, row) do
    case expire_target(acc, row) do
      {:ok, lot} -> expired(acc, row, lot, -row.amount)
      {:flag, _name, _detail} = flagged -> flagged
    end
  end

  # **An expiry can ask for more than its lot holds, and a hold is why.**
  # The legacy ledger has no per-grant reservation at all: `held` is one number
  # for the wallet. Two of its functions act on that missing idea and both
  # produce an expire row the lots cannot reproduce.
  #
  #   * `Ledger.expire_locked/4` clamps by `max(balance - held, 0)`, the whole
  #     wallet's spendable figure, so when other grants cover the held amount it
  #     destroys a grant in full although a live hold was reserving part of
  #     **that** grant (finding X261).
  #   * `Promotions.consume/3` gives a spend to the soonest-expiring grant with
  #     `remaining > 0`, with no idea a hold has reserved it. The lot model
  #     cannot spend a reservation, so it takes the spend from the **next**
  #     grant, and the two attributions then differ by what was reserved. The
  #     later expiry of that next grant asks for more than the lot has, and
  #     that lot's own `reserved` is zero (finding X276).
  #
  # The bound is therefore the reservation **anywhere in the wallet**, not on
  # this lot: a spend the lot model could not take where the legacy fold took
  # it was blocked by a reservation somewhere, and that is the only way the two
  # can disagree. Keying on `lot.reserved` alone called X276's wallet corrupt,
  # which is the wrong thing to tell an operator: there is nothing to repair.
  #
  # Above that bound no reservation explains the gap, and `expire_over_lot`
  # means what it says: this row does not belong to this grant.
  defp expired(acc, row, lot, amount) when amount >= 0 do
    reserved = acc.book |> Enum.map(& &1.reserved) |> Enum.sum()

    cond do
      amount <= lot.available ->
        movements = expire_movements(lot.id, amount)
        {:ok, acc, %{movements: movements, debt_delta: 0, book: move(acc.book, movements)}}

      amount <= lot.available + reserved ->
        {:flag, :expire_reserved_grant, expire_detail(row, lot, amount, reserved)}

      true ->
        {:flag, :expire_over_lot, expire_detail(row, lot, amount, reserved)}
    end
  end

  defp expired(_acc, row, _lot, amount),
    do: {:flag, :unsupported_row, %{kind: :expire, amount: amount, id: row.id}}

  defp expire_detail(row, lot, amount, wallet_reserved) do
    %{
      reference: row.reference,
      amount: amount,
      available: lot.available,
      reserved: lot.reserved,
      wallet_reserved: wallet_reserved,
      id: row.id
    }
  end

  defp expire_movements(_lot_id, 0), do: []

  defp expire_movements(lot_id, amount),
    do: [%{lot_id: lot_id, from: :available, to: :expired, amount: amount, kind: :expire}]

  defp expire_target(acc, row) do
    grant_id = row.metadata["grant_id"]

    with true <- is_binary(grant_id),
         {:ok, lot_id} <- Map.fetch(acc.by_grant, grant_id),
         %{} = lot <- Enum.find(acc.book, &(&1.id == lot_id)) do
      {:ok, lot}
    else
      _absent -> {:flag, :expire_unattributed, %{reference: row.reference, grant_id: grant_id}}
    end
  end

  defp move(book, movements) do
    Enum.reduce(movements, book, fn movement, acc ->
      Enum.map(acc, &move_one(&1, movement))
    end)
  end

  defp move_one(%{id: id} = lot, %{lot_id: id} = movement) do
    lot
    |> Map.update!(movement.from, &(&1 - movement.amount))
    |> Map.update!(movement.to, &(&1 + movement.amount))
  end

  defp move_one(lot, _movement), do: lot

  # -- applying one plan ------------------------------------------------------

  defp apply_plan(acc, row, plan) do
    deltas = deltas(acc, plan)

    acc = %{
      acc
      | book: plan.book,
        debt: acc.debt + Map.get(plan, :debt_delta, 0),
        balance: acc.balance + deltas.balance,
        held: acc.held + deltas.held,
        promotional: acc.promotional + deltas.promotional,
        allocations: allocations(acc, row, plan)
    }

    case chain(acc, row) do
      :ok -> {:cont, promotional_note(acc, row, plan)}
      {:flag, name, detail} -> {:halt, {:blocked, [flag(name, detail) | acc.flags]}}
    end
  end

  defp deltas(acc, plan) do
    plan.movements
    |> Enum.reduce(new_lot_deltas(plan), fn movement, sums ->
      contribution = contribution(movement)
      category = category(acc, plan, movement.lot_id)

      %{
        balance: sums.balance + contribution,
        held: sums.held + held_delta(movement),
        promotional: sums.promotional + promotional(category, contribution)
      }
    end)
    |> Map.update!(:balance, &(&1 - Map.get(plan, :debt_delta, 0)))
  end

  defp new_lot_deltas(plan) do
    case Map.get(plan, :new_lot) do
      nil -> %{balance: 0, held: 0, promotional: 0}
      lot -> %{balance: lot.amount, held: 0, promotional: promotional(lot.category, lot.amount)}
    end
  end

  defp category(acc, plan, lot_id) do
    case Map.fetch(acc.categories, lot_id) do
      {:ok, category} -> category
      :error -> plan.new_lot && plan.new_lot.category
    end
  end

  defp promotional(:promotional, amount), do: amount
  defp promotional(_category, _amount), do: 0

  defp contribution(%{from: from, to: to, amount: amount}),
    do: into(to, amount, @contribution) - into(from, amount, @contribution)

  defp held_delta(%{from: from, to: to, amount: amount}),
    do: into(to, amount, [:reserved]) - into(from, amount, [:reserved])

  defp into(bucket, amount, buckets), do: if(bucket in buckets, do: amount, else: 0)

  defp allocations(acc, row, plan) do
    Enum.reduce(plan.movements, acc.allocations, fn movement, list ->
      [allocation(acc.tenant_key, row, movement) | list]
    end)
  end

  defp allocation(tenant_key, row, movement) do
    %{
      tenant_key: tenant_key,
      lot_id: movement.lot_id,
      transaction_id: row.id,
      kind: movement.kind,
      from_bucket: movement.from,
      to_bucket: movement.to,
      amount: movement.amount,
      inserted_at: row.inserted_at
    }
  end

  # **The oracle, applied once per row rather than once per wallet.**
  #
  # `balance_after` and `held_after` were written by the legacy ledger under
  # the balance row's lock, so within one wallet they form an exact chain in
  # true commit order. A fold that reproduces them row for row has reproduced
  # the history; one that does not has either a bug or the rows in the wrong
  # order, and either way it must not write.
  defp chain(acc, row) do
    cond do
      acc.balance != row.balance_after ->
        {:flag, :ledger_chain_mismatch, chain_detail(acc, row, :balance, row.balance_after)}

      acc.held != row.held_after ->
        {:flag, :ledger_chain_mismatch, chain_detail(acc, row, :held, row.held_after)}

      is_integer(row.promotional_after) and acc.promotional != row.promotional_after ->
        {:flag, :promotional_divergence,
         chain_detail(acc, row, :promotional, row.promotional_after)}

      true ->
        :ok
    end
  end

  defp chain_detail(acc, row, field, expected) do
    %{
      field: field,
      replayed: Map.fetch!(acc, field),
      row: expected,
      reference: row.reference,
      kind: row.kind,
      id: row.id
    }
  end

  # Informational. A promotional grant that landed while the wallet owed money
  # became spendable only above zero, which `AuroraMeter.Credits.Promotions`
  # expressed by attributing less than the grant's amount and the lot model
  # expresses by repaying the debt out of the new lot. The same figure by a
  # different route, and worth naming in the report because an operator looking
  # at a 5 USD lot whose available is 2 USD deserves to know why.
  defp promotional_note(acc, row, plan) do
    if Map.get(plan, :new_lot) && row.category == :promotional && plan.debt_delta != 0 do
      note(acc, :promotional_clamped, %{reference: row.reference, repaid: -plan.debt_delta})
    else
      acc
    end
  end

  # -- provenance -------------------------------------------------------------

  defp source_for(%{category: :paid} = row) do
    if payment_intent?(row.reference) do
      {:ok, %{"legacy" => true, "payment_intent_id" => row.reference}}
    else
      {:ok, %{"legacy" => true, "reference" => row.reference}}
    end
  end

  defp source_for(%{category: :promotional} = row),
    do: {:ok, %{"legacy" => true, "promotion" => row.reference}}

  defp source_for(%{category: :adjustment} = row) do
    case restore_prefix(row.reference) do
      nil -> {:ok, %{"legacy" => true, "reference" => row.reference}}
      prefix -> restored_source(row, prefix)
    end
  end

  defp restored_source(row, prefix) do
    case parse_intent(row.reference, prefix) do
      nil ->
        {:error, :unparsable_restore_reference,
         %{reference: row.reference, prefix: prefix, id: row.id}}

      intent ->
        {:ok, %{"legacy" => true, "payment_intent_id" => intent, "reference" => row.reference}}
    end
  end

  defp restore_prefix(reference) when is_binary(reference),
    do: Enum.find(@restore_prefixes, &String.starts_with?(reference, &1))

  defp restore_prefix(_reference), do: nil

  defp payment_intent(acc, row),
    do: from_metadata(row) || from_reference(row) || from_grant_reference(acc, row)

  defp from_metadata(row) do
    case row.metadata["payment_intent_id"] do
      intent when is_binary(intent) -> intent
      _absent -> nil
    end
  end

  defp from_reference(%{reference: reference}) when is_binary(reference) do
    case Enum.find(@reversal_prefixes, &String.starts_with?(reference, &1)) do
      nil -> nil
      prefix -> parse_intent(reference, prefix)
    end
  end

  defp from_reference(_row), do: nil

  # The lot a named grant reference created, and then that lot's own payment
  # intent. It is a lookup, not an invention: when the grant carries no intent
  # the answer is `nil` and the wallet blocks.
  defp from_grant_reference(acc, row) do
    with reference when is_binary(reference) <- row.metadata["grant_reference"],
         {:ok, lot_id} <- Map.fetch(acc.by_reference, reference),
         %{source: source} <- Enum.find(acc.lots, &(&1.id == lot_id)),
         intent when is_binary(intent) <- source["payment_intent_id"] do
      intent
    else
      _absent -> nil
    end
  end

  defp parse_intent(reference, prefix) do
    candidate =
      reference
      |> String.replace_prefix(prefix, "")
      |> String.split(":")
      |> List.first()

    if payment_intent?(candidate), do: candidate
  end

  defp payment_intent?(value) when is_binary(value), do: Regex.match?(@payment_intent, value)
  defp payment_intent?(_value), do: false
end
