if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.ObanTestReconciler do
    @moduledoc false
    @behaviour AuroraMeter.Credits.HoldReconciler

    @impl AuroraMeter.Credits.HoldReconciler
    def decide(_hold), do: :release
  end

  defmodule AuroraMeter.Oban.WorkersTest do
    @moduledoc """
    What each worker's `perform/1` does with its operation's result.

    The concurrency half, where two runs of one worker contend for the same
    row, is `test/aurora_meter/oban_concurrency_test.exs`: it needs real
    connections and this file does not.
    """
    use AuroraMeter.DataCase, async: false

    alias AuroraMeter.Credits
    alias AuroraMeter.Oban.CreditExpiry
    alias AuroraMeter.Oban.EventsReplay
    alias AuroraMeter.Oban.HoldReconciliation
    alias AuroraMeter.Oban.PlanTransitions
    alias AuroraMeter.Oban.RecurringGrants
    alias AuroraMeter.Test.Config, as: TestConfig
    alias AuroraMeter.Test.Faults

    defp job(args \\ %{}), do: %Oban.Job{args: args}

    defp due_grant(tenant, reference) do
      {:ok, txn} =
        Credits.grant(tenant, 1_000_000,
          reference: reference,
          category: :promotional,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        )

      txn
    end

    defp expiries(tenant) do
      tenant |> Credits.history() |> Enum.filter(&(&1.kind == :expire))
    end

    test "I16 a second CreditExpiry run for the same tick expires nothing and adds no ledger row" do
      tenant = unique_tenant("obanexp")
      due_grant(tenant, "promo_a:#{tenant}")
      due_grant(tenant, "promo_b:#{tenant}")

      assert {:ok, %{counts: %{"expired" => 2}}} = CreditExpiry.perform(job())
      before = expiries(tenant)

      # The only layer in play here is the one inside the operation. Oban's
      # uniqueness deduplicates JOBS and there is no Oban instance in this test:
      # `perform/1` is called twice directly, so a green result can only come
      # from `expire_due/1` re-reading `expired_at` under the grant row's
      # `FOR UPDATE` (X125: name the layer that answered).
      assert {:ok, %{counts: %{"expired" => 0, "examined" => 0}}} =
               CreditExpiry.perform(job())

      assert expiries(tenant) == before
    end

    describe "CreditExpiry" do
      test "expires every due grant and reports what it did" do
        tenant = unique_tenant("obanexp")
        due_grant(tenant, "promo_a:#{tenant}")
        due_grant(tenant, "promo_b:#{tenant}")

        # Build unit 05c: the worker runs bounded batches and returns the run's
        # report rather than a bare count, so the count is one field of it.
        assert {:ok, report} = CreditExpiry.perform(job())
        assert report.counts["expired"] == 2
        assert report.stopped == :complete
        assert length(expiries(tenant)) == 2

        assert %{balance: 0, promotional: 0} =
                 Map.take(Credits.balance(tenant), ~w(balance promotional)a)
      end

      test "declares the queue, three attempts and a uniqueness that is defence in depth" do
        opts = CreditExpiry.__opts__()

        assert opts[:queue] == :aurora_meter
        assert opts[:max_attempts] == 3
        assert opts[:unique][:period] == :infinity
        refute :completed in opts[:unique][:states]
      end

      test "builds a valid job through new/1" do
        assert %Ecto.Changeset{valid?: true} = CreditExpiry.new(%{})
      end
    end

    describe "HoldReconciliation" do
      test "translates its job arguments into reconcile_holds/1 options" do
        opts =
          HoldReconciliation.options(%{
            "older_than_seconds" => 600,
            "limit" => 25,
            "reference_prefix" => "job:",
            "tenant" => "org_1"
          })

        assert opts[:limit] == 25
        assert opts[:reference_prefix] == "job:"
        assert opts[:tenant] == "org_1"
        assert DateTime.diff(AuroraMeter.Clock.now(), opts[:older_than], :second) in 595..605
      end

      test "defaults to an hour and a bounded page, and carries no other option" do
        opts = HoldReconciliation.options(%{})

        # 05c added `:limit`: an unbounded reconciliation page is exactly the
        # thing job controls exist to stop.
        assert Enum.sort(Keyword.keys(opts)) == [:limit, :older_than]
        assert opts[:limit] == 200
        assert DateTime.diff(AuroraMeter.Clock.now(), opts[:older_than], :second) in 3595..3605
      end

      test "keeps every hold when no reconciler is configured" do
        tenant = unique_tenant("obanhold")
        {:ok, _} = Credits.grant(tenant, 1_000_000, reference: "seed:#{tenant}")
        {:ok, _} = Credits.hold(tenant, 400_000, "job:#{tenant}")

        # A cutoff one second in the future, so the hold just written is
        # certainly on the old side of it. The two instants come from two node
        # wall clocks (this one, and Ecto's autogenerate on the row: finding
        # X181), which can disagree by milliseconds.
        assert {:ok, report} = HoldReconciliation.perform(job(%{"older_than_seconds" => -1}))

        assert report.counts["examined"] == 1
        assert report.counts["kept"] == 1
        assert report.counts["released"] == 0
        assert report.counts["settled"] == 0
        assert %{held: 400_000, available: 600_000} = Credits.balance(tenant)
      end

      test "applies the configured reconciler's decision" do
        tenant = unique_tenant("obanhold")
        {:ok, _} = Credits.grant(tenant, 1_000_000, reference: "seed:#{tenant}")
        {:ok, _} = Credits.hold(tenant, 400_000, "job:#{tenant}")

        reconciler = AuroraMeter.ObanTestReconciler

        TestConfig.with_config([{:aurora_meter, :credits_hold_reconciler, reconciler}], fn ->
          assert {:ok, report} = HoldReconciliation.perform(job(%{"older_than_seconds" => -1}))
          assert report.counts["released"] == 1
        end)

        assert %{held: 0, available: 1_000_000} = Credits.balance(tenant)
      end

      test "L05a-1 returns {:error, reason} rather than raising when the listing fails" do
        tenant = unique_tenant("obanhold")
        {:ok, _} = Credits.grant(tenant, 1_000_000, reference: "seed:#{tenant}")
        {:ok, _} = Credits.hold(tenant, 400_000, "job:#{tenant}")

        opts = HoldReconciliation.options(%{"older_than_seconds" => -1, "tenant" => tenant})

        TestConfig.with_config([{:aurora_meter, :repo, AuroraMeter.Test.FaultRepo}], fn ->
          arm_listing_fault()

          assert {:error, %Faults.Injected{}} =
                   HoldReconciliation.perform(
                     job(%{"older_than_seconds" => -1, "tenant" => tenant})
                   )

          # The negative control, and it is the whole point of L05a-1. The same
          # value, through the shape `AuroraMeter.Pro.Credits.Expirer` used
          # before this unit, raises instead of failing the job. One layer, and
          # the assertion names which one: the worker's own mapping.
          arm_listing_fault()

          assert_raise MatchError, fn ->
            {:ok, _report} = Credits.reconcile_holds(opts)
          end
        end)
      end

      test "declares the queue, three attempts and uniqueness" do
        opts = HoldReconciliation.__opts__()

        assert opts[:queue] == :aurora_meter
        assert opts[:max_attempts] == 3
        assert opts[:unique][:period] == :infinity
      end
    end

    describe "EventsReplay" do
      test "translates its job arguments into Replay.run/1 options" do
        opts =
          EventsReplay.options(%{
            "batch_size" => 100,
            "compare" => "report",
            "activate" => false,
            "nonsense" => 1
          })

        assert Keyword.equal?(opts, batch_size: 100, compare: :report, activate: false)
      end

      test "reports a paused run as a success carrying its status" do
        # The branch a replay reaches only when an operator pauses it mid run.
        # It is exercised here rather than left to a replay that would have to
        # be paused to reach it (`open-findings.md` X182: a branch no test can
        # reach is a branch nothing knows the shape of).
        assert EventsReplay.translate({:ok, :paused, %{active_generation: 3}}) ==
                 {:ok, %{active_generation: 3, paused: true}}

        assert EventsReplay.translate({:ok, %{scanned: 10}}) == {:ok, %{scanned: 10}}
        assert EventsReplay.translate({:error, :boom}) == {:error, :boom}
      end

      test "is a single-attempt worker, because a replay resumes from a checkpoint" do
        assert EventsReplay.__opts__()[:max_attempts] == 1
      end
    end

    describe "the worker whose operation is not in this release" do
      test "PlanTransitions cancels with :not_implemented" do
        refute function_exported?(AuroraMeter.Subscriptions, :apply_due_transitions, 1)
        assert PlanTransitions.perform(job()) == {:cancel, :not_implemented}
      end
    end

    describe "RecurringGrants, whose operation arrived in build unit 06d" do
      test "runs the sweep and maps its return, with no edit to the worker" do
        assert Code.ensure_loaded?(AuroraMeter.Credits.Recurrences)

        assert {:ok, %{counts: counts}} =
                 RecurringGrants.perform(job(%{"limit" => 1, "batch" => 1}))

        assert is_map(counts)
      end

      test "passes only the options the operation declares, and only those the job carries" do
        # Args carry ids and scalars, never a policy and never an amount
        # (`architecture-map.md` section 6). An unknown key is ignored rather
        # than raising: a job that cannot be fixed by editing the crontab is a
        # job that fails until somebody finds it.
        assert {:ok, %{counts: %{"examined" => examined}}} =
                 RecurringGrants.perform(job(%{"limit" => 1, "batch" => 1, "amount" => 999}))

        assert examined <= 1
      end
    end

    defp arm_listing_fault do
      Faults.arm(:before_commit, :raise,
        count: 1,
        label: :hold_listing,
        when: fn context ->
          context[:repo_fun] == :all and context[:schema] == AuroraMeter.Schema.CreditTransaction
        end
      )
    end
  end

  defmodule ReleaseAll do
    @moduledoc false
    @behaviour AuroraMeter.Credits.HoldReconciler

    @impl true
    def decide(_hold), do: :release
  end
end
