if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.ObanJobControlsTest do
    @moduledoc """
    The batch loop, per core worker: bounded batches, a cursor that resumes, a
    pause that lands within one batch, and a per-item failure that is counted
    and stepped over rather than failing the run.

    Invariant I16 is this unit's, and these are its core half. Not
    `AuroraMeter.DataCase`: a killed process cannot be killed inside the sandbox
    without taking the test's own connection with it, and the resume claim is
    only a claim if the batches before the kill really committed. Every task here
    takes a real connection and the assertions are on rows.
    """
    use ExUnit.Case, async: false

    import Ecto.Query, only: [from: 2]

    alias AuroraMeter.Credits
    alias AuroraMeter.Credits.Promotions
    alias AuroraMeter.Oban.CreditExpiry
    alias AuroraMeter.Oban.HoldReconciliation
    alias AuroraMeter.Operations
    alias AuroraMeter.Schema.CreditTransaction
    alias AuroraMeter.Test.Config, as: TestConfig
    alias AuroraMeter.Test.Connections
    alias AuroraMeter.Test.FaultRepo
    alias AuroraMeter.Test.Faults
    alias AuroraMeter.TestRepo
    alias Ecto.Adapters.SQL.Sandbox

    @moduletag timeout: 120_000

    setup do
      :ok = Sandbox.checkout(TestRepo, sandbox: false)
      tenant = AuroraMeter.Test.unique_tenant("jobctl")

      # Each test gets its own operation name, so the checkpoint rows of two
      # tests can never be read as each other's. `Connections.cleanup!/1` is
      # prefix bounded and cannot reach `aurora_meter_checkpoints`, so the
      # checkpoint is cleared here by name.
      operation = "credit_expiry:" <> tenant
      reconciliation = "hold_reconciliation:" <> tenant

      on_exit(fn ->
        :ok = Sandbox.checkout(TestRepo, sandbox: false)
        Operations.clear_checkpoint(operation)
        Operations.clear_checkpoint(reconciliation)
        Operations.clear_checkpoint(CreditExpiry.operation())
        Operations.clear_checkpoint(HoldReconciliation.operation())
        Connections.cleanup!(tenant)
        Sandbox.checkin(TestRepo)
      end)

      {:ok, tenant: tenant, operation: operation, reconciliation: reconciliation}
    end

    test "I16 CreditExpiry processes at most batch_size grants per batch and records a cursor",
         %{tenant: tenant} do
      grants = due_grants(tenant, 25)

      assert {:ok, report} =
               CreditExpiry.perform(job(%{"batch_size" => 10, "max_batches" => 1}))

      assert report.batches == 1
      assert report.stopped == :max_batches
      assert report.counts["examined"] == 10

      # Ten rows, not twenty five: the batch really was bounded, and the
      # bound is what the argument said.
      assert expiry_count(tenant) == 10

      # And the cursor names both halves of the keyset plus the instant the
      # scan was pinned to.
      cursor = Operations.checkpoint(CreditExpiry.operation()).cursor
      assert %{"now" => _, "expires_at" => _, "id" => id} = cursor
      assert id in Enum.map(grants, & &1.id)
    end

    test "I16 CreditExpiry killed between batches resumes at the checkpoint without skipping work",
         %{tenant: tenant} do
      grants = due_grants(tenant, 50)

      # The fault point is the batch boundary itself: a telemetry handler runs
      # in the worker's own process, immediately after the checkpoint write and
      # before the next batch, so `Process.exit(self(), :kill)` there is exactly
      # "killed between batches" with nothing simulated.
      killed = kill_after_batches(2, fn -> CreditExpiry.perform(job(%{"batch_size" => 10})) end)

      assert killed == {:exit, :killed}

      # Work committed, and the scan did not finish. **The exact count is not
      # asserted**, and the reason is a defect this test found rather than a
      # looseness it wanted: `AuroraMeter.Credits.Promotions.consume/3` raises
      # `KeyError` when an `:expire` entry sorts before its own grant, which the
      # ledger's node-stamped `inserted_at` makes reachable whenever the wall
      # clock steps backwards mid-run (`open-findings.md` X213, and X181/L20
      # before it). `expire_due/2` counts such a grant as `failed` and carries
      # on, so a run can commit fewer than a whole batch. The deterministic
      # reproduction is the next test.
      committed = expiry_count(tenant)
      assert committed > 0, "the kill landed before any batch committed"
      assert committed < 50, "the run finished before the kill landed"
      assert %{"id" => _} = Operations.checkpoint(CreditExpiry.operation()).cursor

      # **This is the claim, and it is exact.** The next run examines precisely
      # the grants the cursor has not passed, so the cursor is neither ahead of
      # the committed work (which would skip) nor behind it (which would repeat).
      assert {:ok, report} = CreditExpiry.perform(job(%{"batch_size" => 10}))
      assert report.counts["examined"] == 50 - committed

      # Then drained, because a grant the ledger refused with X213 is still due
      # and the next run is what expires it. A scheduled sweep runs repeatedly;
      # this is that, bounded.
      passes = drain(tenant, 10)

      # Exactly once each, in total, with nothing skipped: fifty grants, fifty
      # expiry rows, every grant stamped.
      assert expiry_count(tenant) == 50
      assert Enum.all?(grants, &expired?/1)

      race_report(%{test: :kill_resume, committed_before_kill: committed, drain_passes: passes})
    end

    test "I16 an expire entry stamped before its own grant expires the right amount, because the fold orders by seq",
         %{tenant: tenant} do
      # **This test changed in build unit 06a, and it changed because the defect
      # it reproduced is fixed.** It used to assert `failed: 1`, `expired: 0` and
      # a `KeyError` in the log, and the planting below is deliberately
      # unchanged so that reverting the fix makes it fail rather than pass
      # either way.
      #
      # What it reproduced: `remaining_on_grant/3` streamed a tenant's
      # promotional grants and negative entries ordered by `(inserted_at, id)`
      # and `Promotions.consume/3` folded them, which needs an `:expire` entry's
      # grant to have been folded already. `inserted_at` is stamped by Ecto's
      # autogenerate from the node wall clock (X181) and that clock steps
      # backwards by up to 2.6 s on this host (X59, X100), so an expire row
      # written after its grant could carry an earlier timestamp and sort before
      # it. It cost 7 of 50 expiries in one run of the test above (X213).
      #
      # What fixed it: schema version 9 put `seq bigint GENERATED ALWAYS AS
      # IDENTITY` on `aurora_meter_credit_transactions`, and the fold orders by
      # it. A sequence is assigned in commit order and cannot go backwards.
      grant = hd(due_grants(tenant, 1))
      plant_early_expire(grant)

      # The planted row is itself an expiry row, so the baseline is one and not
      # zero. Captured rather than assumed.
      planted = expiry_count(tenant)
      assert planted == 1

      # **The negative control, and it is what carries the claim.** Fed the same
      # committed rows in the order the ledger used to use, the fold still
      # believes the grant is untouched; fed them in `seq` order it sees the
      # micro-dollar the planted row took. If `seq` were put back to
      # `inserted_at` these two numbers would be the same and this would fail.
      assert fold_remaining(tenant, grant.id, :inserted_at) == 1_000_000
      assert fold_remaining(tenant, grant.id, :seq) == 999_999

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, report} = Credits.expire_due(now(), limit: 10)

          assert report.examined == 1
          assert report.expired == 1
          assert report.failed == 0
        end)

      refute log =~ "KeyError"

      # **The end-to-end assertion that discriminates.** The expiry row's amount
      # is the grant's real remainder, not its face value: under the old
      # ordering the ledger would have written off the whole 1,000,000 and
      # destroyed a micro-dollar that had already been spent.
      assert expiry_count(tenant) == planted + 1
      assert newest_expiry(tenant).amount == -999_999
      assert expired?(grant)
    end

    test "I16 CreditExpiry re-processes one batch when killed between the batch commit and the checkpoint write, with no second effect",
         %{tenant: tenant, operation: operation} do
      grants = due_grants(tenant, 20)

      # The callback commits its batch and then dies before returning, which is
      # the one window `Operations`' documentation says it leaves open: the
      # work is committed and the cursor is not.
      parent = self()

      pid =
        spawn(fn ->
          Connections.checkout!()

          Operations.run_batches(operation, [], fn cursor ->
            {:ok, report} = Credits.expire_due(now(), limit: 10, after: keyset(cursor))
            send(parent, {:committed, report.expired})
            Process.exit(self(), :kill)
            {:ok, %{cursor: nil}}
          end)
        end)

      ref = Process.monitor(pid)
      assert_receive {:committed, 10}, 10_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 10_000

      # Committed, and no cursor: the next run starts the scan again.
      assert expiry_count(tenant) == 10

      assert Operations.checkpoint(operation) in [nil, %{}] or
               Operations.checkpoint(operation).cursor == %{}

      assert {:ok, report} =
               Operations.run_batches(operation, [], fn cursor ->
                 {:ok, r} = Credits.expire_due(now(), limit: 10, after: keyset(cursor))
                 {:ok, %{cursor: cursor_of(r), counts: counts(r)}}
               end)

      # Twenty grants, twenty expiry rows: the re-processed batch produced no
      # second effect.
      assert expiry_count(tenant) == 20
      assert Enum.all?(grants, &expired?/1)

      # **Which layer refused it.** The re-run re-selected the ten already
      # expired grants (their `expired_at` is set, so in fact it did not: the
      # listing predicate excludes them). That is the honest reading and it is
      # why the count below is what it is: the candidate query, not the row
      # lock, is what keeps the second pass cheap. The row-lock re-read is the
      # layer that answers when two runs race, and 05a's rendezvous test is
      # where that is proved.
      assert report.counts["examined"] == 10
      assert report.counts["expired"] == 10
      assert report.counts["skipped"] == 0
    end

    test "I16 a rewound cursor re-examines committed work and the ledger refuses it, not the cursor",
         %{tenant: tenant, operation: operation} do
      # The X125 discipline: the "no second effect" claim above is guarded
      # twice, by the candidate query excluding expired grants and by
      # `expire_grant/2`'s `expired_at` re-read under the row lock. The test
      # above cannot tell them apart, because the query answers first. This one
      # can: it puts the grants back in the candidate set by clearing
      # `expired_at` on the ledger rows while leaving the expiry entries in
      # place, so the only thing that can refuse a second expiry entry is the
      # unique index on `(kind, reference)`.
      grants = due_grants(tenant, 5)

      assert {:ok, _} = Credits.expire_due(now(), limit: 5)
      assert expiry_count(tenant) == 5

      TestRepo.update_all(
        from(t in CreditTransaction,
          where: t.id in ^Enum.map(grants, & &1.id)
        ),
        set: [expired_at: nil]
      )

      :ok = Operations.put_checkpoint(operation, cursor: nil)

      {:ok, report} = Credits.expire_due(now(), limit: 5)

      # Every one of them was a candidate again, and every one was refused.
      assert report.examined == 5
      assert report.expired == 0
      assert report.skipped == 5

      # Still five expiry rows. The layer that answered here is the unique
      # index on `(kind, reference)`, surfaced as a refusal rather than a
      # raise, because `expired_at` had been cleared behind the ledger's back.
      assert expiry_count(tenant) == 5
    end

    test "I16 CreditExpiry cancels with :paused and continues from the cursor after resume",
         %{tenant: tenant} do
      grants = due_grants(tenant, 30)

      assert {:ok, report} = CreditExpiry.perform(job(%{"batch_size" => 10, "max_batches" => 1}))
      assert report.counts["examined"] == 10

      :ok = Operations.pause(CreditExpiry.operation())
      before = Operations.checkpoint(CreditExpiry.operation()).cursor

      assert {:cancel, :paused} = CreditExpiry.perform(job(%{"batch_size" => 10}))

      # Nothing moved, and the cursor is exactly where it was.
      assert expiry_count(tenant) == 10
      assert Operations.checkpoint(CreditExpiry.operation()).cursor == before

      :ok = Operations.resume(CreditExpiry.operation())

      assert {:ok, resumed} = CreditExpiry.perform(job(%{"batch_size" => 10}))
      assert resumed.stopped == :complete
      assert expiry_count(tenant) == 30
      assert Enum.all?(grants, &expired?/1)
    end

    test "I16 CreditExpiry counts a grant the ledger refuses and expires the ones before it",
         %{tenant: tenant} do
      # A grant whose whole remainder a pending hold has reserved. The ledger
      # refuses to claw it back (`:held`), which is a per-item refusal inside
      # a batch: it is counted as skipped, the cursor steps over it, and the
      # run finishes normally rather than failing.
      #
      # It is the **last** grant in the scan on purpose. `:held` is a
      # balance-wide condition, not a per-grant one: the predicate is
      # `balance - held`, so once a hold has taken the whole spendable balance
      # every grant after it in the same scan is refused too. A fixture that
      # put the held grant in the middle would refuse the tail as well, and
      # the test would be asserting something the ledger does not do.
      earlier = due_grants(tenant, 4)
      held = held_grant(tenant)

      assert {:ok, report} = CreditExpiry.perform(job(%{"batch_size" => 10}))

      assert report.stopped == :complete
      assert report.counts["examined"] == 5
      assert report.counts["expired"] == 4
      assert report.counts["skipped"] == 1
      assert report.counts["failed"] == 0

      refute expired?(held)
      assert Enum.all?(earlier, &expired?/1)
    end

    test "I16 CreditExpiry counts a grant whose transaction raises, advances past it, and expires the rest",
         %{tenant: tenant} do
      # L05c-3's other half, and the one that matters operationally: a
      # transaction that ends badly for one grant must not cost the grants
      # behind it their sweep. Injected with the 01b fault repo rather than
      # simulated, so the raise comes out of the real statement.
      grants = due_grants(tenant, 5)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      TestConfig.with_config(
        [{:aurora_meter, :repo, FaultRepo}],
        fn ->
          Faults.arm(:before_commit, :raise,
            count: 1,
            label: :expire_one_grant,
            when: fn context ->
              context[:repo_fun] == :one! and
                context[:schema] == CreditTransaction and
                Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) == 3
            end
          )

          assert {:ok, report} = CreditExpiry.perform(job(%{"batch_size" => 10}))

          assert report.stopped == :complete
          assert report.counts["examined"] == 5
          assert report.counts["failed"] == 1
          assert report.counts["expired"] == 4

          Faults.assert_fired!(:before_commit)
        end
      )

      Agent.stop(counter)

      # Four expired, one left. The failed grant is still due, so the next run
      # examines it again: nothing was skipped permanently and nothing was
      # written for it.
      assert expiry_count(tenant) == 4
      assert Enum.count(grants, &expired?/1) == 4

      assert {:ok, second} = CreditExpiry.perform(job(%{"batch_size" => 10}))
      assert second.counts["expired"] == 1
      assert Enum.all?(grants, &expired?/1)
    end

    test "CreditExpiry job args contain only bounded integers, and a bad one falls back" do
      # Task 05.05's args rule, asserted on this worker's own arguments: the
      # cursor is not among them, and neither is anything that could carry a
      # payload. An argument that is not a positive integer is not coerced; it
      # is ignored, so a malformed argument cannot make a batch unbounded.
      assert {:ok, report} =
               CreditExpiry.perform(job(%{"batch_size" => "lots", "max_batches" => -1}))

      assert report.batches <= 10
    end

    test "I16 HoldReconciliation pages with a cursor and finishes the scan", %{tenant: tenant} do
      holds = pending_holds(tenant, 12)

      args = %{"older_than_seconds" => 0, "limit" => 5}

      assert {:ok, report} = HoldReconciliation.perform(job(args))

      assert report.stopped == :complete
      assert report.batches == 3
      assert report.counts["examined"] == 12
      assert report.counts["kept"] == 12

      # No reconciler is configured, so every hold is kept: the run walked
      # them all and changed nothing, which is the documented default.
      assert length(pending(tenant)) == length(holds)
      assert Operations.checkpoint(HoldReconciliation.operation()).cursor == %{}
    end

    test "I16 HoldReconciliation cancels with :paused within one batch", %{tenant: tenant} do
      pending_holds(tenant, 12)

      args = %{"older_than_seconds" => 0, "limit" => 5, "max_batches" => 1}

      assert {:ok, first} = HoldReconciliation.perform(job(args))
      assert first.counts["examined"] == 5

      :ok = Operations.pause(HoldReconciliation.operation())
      before = Operations.checkpoint(HoldReconciliation.operation()).cursor

      assert {:cancel, :paused} = HoldReconciliation.perform(job(args))
      assert Operations.checkpoint(HoldReconciliation.operation()).cursor == before

      :ok = Operations.resume(HoldReconciliation.operation())
      assert {:ok, _} = HoldReconciliation.perform(job(args))
    end

    test "I16 the cutoff is pinned across the pages of one scan", %{tenant: tenant} do
      pending_holds(tenant, 6)

      args = %{"older_than_seconds" => 0, "limit" => 2, "max_batches" => 1}

      assert {:ok, _} = HoldReconciliation.perform(job(args))

      cursor = Operations.checkpoint(HoldReconciliation.operation()).cursor
      assert %{"older_than" => pinned} = cursor

      assert {:ok, _} = HoldReconciliation.perform(job(args))

      # The same cutoff on the second page, not a freshly computed one: the
      # candidate set a cursor points into must be the set it came from.
      assert Operations.checkpoint(HoldReconciliation.operation()).cursor["older_than"] ==
               pinned
    end

    describe "the args allow list" do
      test "every AuroraMeter.Oban worker's documented args are ids or bounded integers" do
        # Enumerated from the registry rather than from a list written here, so
        # a worker added later is covered without an edit (and a worker added
        # later with a payload argument fails this).
        allowed = ~w(batch_size max_batches limit older_than_seconds reference_prefix tenant
                     generation compare compare_limit max_batches activate resume rehydrate
                     timeout since_days older_than_days only max_items)

        for {worker, _operation, _schedule, _description} <- AuroraMeter.Oban.__registry__() do
          documented = documented_args(worker)

          assert documented -- allowed == [],
                 "#{inspect(worker)} documents job arguments outside the allow list: " <>
                   inspect(documented -- allowed)
        end
      end
    end

    # -- fixtures and helpers --------------------------------------------------

    defp job(args), do: %Oban.Job{args: args}

    # Printed when asked for and never otherwise: a test asserts every time and
    # records only when asked (`open-findings.md` X135, X149).
    defp race_report(counts) do
      if System.get_env("AURORA_RACE_REPORT"), do: IO.puts("[05c jobctl] " <> inspect(counts))
      :ok
    end

    # Runs the sweep until it stops making progress, and answers how many passes
    # that took. A scheduled sweep runs repeatedly; a grant the ledger refused
    # this time is still due next time.
    defp drain(tenant, 0), do: flunk("the sweep for #{tenant} never finished draining")

    defp drain(tenant, attempts) do
      before = expiry_count(tenant)
      {:ok, _report} = CreditExpiry.perform(job(%{"batch_size" => 10}))

      if expiry_count(tenant) == before, do: 1, else: 1 + drain(tenant, attempts - 1)
    end

    # An `:expire` entry for `grant`, stamped one second **before** the grant it
    # names, which is what a backwards step of the node clock produces.
    defp plant_early_expire(grant) do
      TestRepo.insert!(%CreditTransaction{
        tenant_key: grant.tenant_key,
        kind: :expire,
        category: :promotional,
        amount: -1,
        balance_after: 0,
        held_after: 0,
        promotional_after: 0,
        reference: "planted:#{System.unique_integer([:positive])}",
        metadata: %{"grant_id" => grant.id},
        inserted_at: DateTime.add(grant.inserted_at, -1, :second)
      })
    end

    defp now, do: AuroraMeter.Clock.db_now()

    defp due_grants(tenant, count) do
      for n <- 1..count do
        {:ok, txn} =
          Credits.grant(tenant, 1_000_000,
            reference: "promo#{n}:#{tenant}",
            category: :promotional,
            expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
          )

        txn
      end
    end

    # A promotional grant whose whole remainder one pending hold has reserved,
    # expiring *after* every grant `due_grants/2` made, so it is the last item
    # of the scan.
    defp held_grant(tenant) do
      {:ok, txn} =
        Credits.grant(tenant, 1_000_000,
          reference: "held:#{tenant}",
          category: :promotional,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        )

      {:ok, _hold} = Credits.hold(tenant, 1_000_000, "hold:#{tenant}")

      txn
    end

    defp pending_holds(tenant, count) do
      {:ok, _} = Credits.grant(tenant, 100_000_000, reference: "funds:#{tenant}")

      for n <- 1..count do
        {:ok, hold} = Credits.hold(tenant, 1_000, "hold#{n}:#{tenant}")
        hold
      end
    end

    defp pending(tenant) do
      TestRepo.all(
        from(t in CreditTransaction,
          where: t.tenant_key == ^tenant and t.kind == ^:hold and t.status == ^:pending
        )
      )
    end

    defp expiry_count(tenant) do
      TestRepo.one!(
        from(t in CreditTransaction,
          where: t.tenant_key == ^tenant and t.kind == ^:expire,
          select: count(t.id)
        )
      )
    end

    defp expired?(grant), do: TestRepo.get!(CreditTransaction, grant.id).expired_at != nil

    # `Ledger.remaining_on_grant/3` reproduced, with the ordering column as an
    # argument so the two orders can be compared on the same committed rows.
    # `repo.all/1` for `repo.stream/1` because this is not inside a transaction.
    defp fold_remaining(tenant, grant_id, order) do
      TestRepo.all(
        from(t in CreditTransaction,
          where:
            t.tenant_key == ^tenant and
              (t.amount < 0 or (t.kind == ^:grant and t.category == ^:promotional)),
          order_by: ^[asc: order]
        )
      )
      |> Promotions.remaining(grant_id)
    end

    defp newest_expiry(tenant) do
      TestRepo.one!(
        from(t in CreditTransaction,
          where: t.tenant_key == ^tenant and t.kind == ^:expire,
          order_by: [desc: t.seq],
          limit: 1
        )
      )
    end

    defp keyset(%{"expires_at" => at, "id" => id}) do
      {:ok, parsed, _} = DateTime.from_iso8601(at)
      {parsed, id}
    end

    defp keyset(_absent), do: nil

    defp cursor_of(%{cursor: nil}), do: nil

    defp cursor_of(%{cursor: {at, id}}),
      do: %{"expires_at" => DateTime.to_iso8601(at), "id" => id}

    defp counts(report) do
      %{
        "examined" => report.examined,
        "expired" => report.expired,
        "skipped" => report.skipped
      }
    end

    # Runs `fun` in its own process on its own connection and kills that process
    # from inside the telemetry handler that fires at the end of batch `n`. The
    # handler runs in the emitting process, so the kill lands exactly at the
    # batch boundary: the batches before it are committed and their cursor is
    # written.
    defp kill_after_batches(n, fun) do
      handler = "jobctl-kill-#{System.unique_integer([:positive])}"
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      :telemetry.attach(
        handler,
        [:aurora_meter, :operations, :batch],
        fn _event, _measurements, _metadata, _config ->
          if Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) >= n do
            Process.exit(self(), :kill)
          end
        end,
        nil
      )

      # `spawn_monitor`, not `Task.async`: a task is linked to the caller, so a
      # `:kill` inside it takes the test process with it. The whole point here
      # is that the worker dies and the test lives to read the rows.
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Connections.checkout!()
          send(parent, {:done, fun.()})
        end)

      result =
        receive do
          {:done, value} ->
            receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok), after: (5_000 -> :ok)
            value

          {:DOWN, ^ref, :process, ^pid, reason} ->
            {:exit, reason}
        after
          30_000 -> flunk("the worker neither finished nor died within 30 s")
        end

      :telemetry.detach(handler)
      Agent.stop(counter)

      result
    end

    # The worker's own moduledoc table is the documentation of its arguments.
    # Reading it here means a worker whose table and whose code disagree is a
    # failure rather than a comment nobody checks.
    defp documented_args(worker) do
      case Code.fetch_docs(worker) do
        {:docs_v1, _, _, _, %{"en" => doc}, _, _} ->
          ~r/\| `"([a-z_]+)"`/
          |> Regex.scan(doc, capture: :all_but_first)
          |> List.flatten()
          |> Enum.uniq()

        _no_docs ->
          []
      end
    end
  end
end
