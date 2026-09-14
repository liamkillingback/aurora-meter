defmodule AuroraMeter.FeatureSourceTest do
  @moduledoc """
  Build unit 03c: one feature, one reporting source (invariant I08).

  The unit's whole claim is a **negative** one: a quantity that arrived as a
  durable event cannot reach `aurora_meter_counters`, which is the only table a
  Pro reporter bills from (`AuroraMeter.Pro.UsageReporter.report_one/5` reads it
  through `AuroraMeter.Storage.load_counter/3`). A negative claim is proved by
  closing every way in, so the tests below are organised by the ways in rather
  than by the functions they call:

    * the guards, which stop a host putting a projected quantity into the
      buffered path by hand (`AuroraMeter.track/4`, `AuroraMeter.reserve/2,3`);
    * the flush path itself, asserted end to end at the shape of the query the
      Pro reporter makes;
    * `AuroraMeter.with_quota/4`, the one remaining writer of `pending_flush`
      that an events-source feature can still reach, which this unit teaches to
      release instead of commit;
    * the configuration, where a declaration that would make the question
      ambiguous is refused at boot.

  `async: false`: every test here touches the node-wide ETS tables, the
  node-wide configuration token, or both.
  """
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test.Config, only: [with_config: 2]
  import ExUnit.CaptureLog

  alias AuroraMeter.Cluster
  alias AuroraMeter.Config
  alias AuroraMeter.Config.Schema
  alias AuroraMeter.Counter
  alias AuroraMeter.Events
  alias AuroraMeter.Flusher
  alias AuroraMeter.Period
  alias AuroraMeter.Schema.Event
  alias AuroraMeter.Storage
  alias AuroraMeter.Store
  alias AuroraMeter.Test.RecordingOutbox

  @events_source [{:aurora_meter, :feature_sources, %{ai_generations: :events}}]

  setup do
    RecordingOutbox.start!()
    tenant = unique_tenant("src")
    {:ok, tenant: tenant, period: Period.current!(tenant).start, at: AuroraMeter.Clock.now()}
  end

  describe "configuration" do
    test "feature_source/1 is :buffered for a feature no configuration names" do
      assert Config.feature_source(:ai_generations) == :buffered
      assert Config.feature_source(:a_name_nothing_declares) == :buffered
      assert Config.events_features() == MapSet.new()
    end

    test "I08 declaring a feature in durable_features and as an events source fails at boot" do
      error =
        with_config(
          [
            {:aurora_meter, :durable_features, [:ai_generations]},
            {:aurora_meter, :feature_sources, %{ai_generations: :events}}
          ],
          fn -> assert_raise ArgumentError, fn -> Config.validate!() end end
        )

      assert error.message =~ ":ai_generations"
      assert error.message =~ ":durable_features"
      assert error.message =~ ":feature_sources"
      assert error.message =~ "exactly one reporting source"

      # X97: the region restored what it borrowed, so the next test starts from
      # the shipped default rather than from this one's wreckage.
      assert Config.feature_source(:ai_generations) == :buffered
      assert Config.durable_features() == []
    end

    test "a feature in durable_features alone boots, and one declared :buffered is not a dual declaration" do
      # The negative control for the boot error above (open-findings.md X84).
      # Both halves of the offending configuration, on their own, are ordinary.
      with_config([{:aurora_meter, :durable_features, [:ai_generations]}], fn ->
        assert is_list(Config.validate!())
      end)

      with_config([{:aurora_meter, :feature_sources, %{ai_generations: :buffered}}], fn ->
        assert is_list(Config.validate!())
        assert Config.feature_source(:ai_generations) == :buffered
      end)

      with_config(
        [
          {:aurora_meter, :durable_features, [:ai_generations]},
          {:aurora_meter, :feature_sources, %{ai_generations: :buffered}}
        ],
        fn -> assert is_list(Config.validate!()) end
      )
    end

    test "an events-source feature no plan declares is reported at boot, once per node" do
      Schema.reset_warnings!()

      log =
        capture_log(fn ->
          with_config(
            [{:aurora_meter, :feature_sources, %{no_plan_declares_this: :events}}],
            fn ->
              Config.validate!()
              Config.validate!()
            end
          )
        end)

      assert log =~ ":no_plan_declares_this"
      assert log =~ "no plan"
      assert occurrences(log, "is declared as an events-source feature") == 1
    end

    test "a declared events-source feature is not reported" do
      # The negative control for the warning above: :ai_generations is on three
      # plans, so the only thing that could produce the message is the check
      # actually looking at the plans module.
      Schema.reset_warnings!()

      log =
        capture_log(fn ->
          with_config(@events_source, fn -> Config.validate!() end)
        end)

      refute log =~ "is declared as an events-source feature"
    end

    test "the durable_features deprecation names the key that replaces it, and that key exists" do
      # 02d wrote the deprecation notice before `:feature_sources` existed. The
      # two have to agree, and the cheapest way to keep them agreeing is to
      # assert that the key the notice tells a host to move to is a key the
      # schema declares.
      Schema.reset_warnings!()

      log =
        capture_log(fn ->
          with_config([{:aurora_meter, :durable_features, [:ai_generations]}], fn ->
            Config.validate!()
          end)
        end)

      assert log =~ "durable_features: [:ai_generations] is deprecated"
      assert log =~ "feature_sources"
      assert Keyword.has_key?(Config.schema().schema, :feature_sources)
      assert Map.fetch!(Config.defaults(), :feature_sources) == %{}
    end

    test "a runtime change to feature_sources takes effect only when the cache is rebuilt" do
      # The source is a boot-time property, and this test is the documentation
      # of that rather than a complaint about it: a source that could change
      # between two calls inside one period is the double count the key exists
      # to prevent.
      tenant = unique_tenant("runtime")

      with_config([{:aurora_meter, :feature_sources, %{}}], fn ->
        assert AuroraMeter.track(tenant, :ai_generations, 1) == :ok

        Application.put_env(:aurora_meter, :feature_sources, %{ai_generations: :events})

        assert Config.feature_sources() == %{ai_generations: :events}
        assert Config.feature_source(:ai_generations) == :buffered
        assert AuroraMeter.track(tenant, :ai_generations, 1) == :ok

        assert Config.refresh!() == :ok
        assert Config.feature_source(:ai_generations) == :events

        assert_raise ArgumentError, fn -> AuroraMeter.track(tenant, :ai_generations, 1) end
      end)

      assert Config.feature_source(:ai_generations) == :buffered
      assert AuroraMeter.usage(tenant, :ai_generations) == 2
    end
  end

  describe "the track and reserve guards" do
    test "I08 track/4 raises for an events-source feature and writes nothing", ctx do
      key = {ctx.tenant, :ai_generations, ctx.period}
      {:ok, _drained} = Flusher.flush()

      with_config(@events_source, fn ->
        error =
          assert_raise ArgumentError, fn -> AuroraMeter.track(ctx.tenant, :ai_generations, 5) end

        assert error.message =~ ":ai_generations"
        assert error.message =~ "AuroraMeter.record/4"
        assert error.message =~ "second, separately billable count"

        # The raise happens before the tenant key is resolved, so there is no
        # ETS row, nothing dirty, and nothing for a flush to find.
        assert Counter.base(key) == nil
        refute key in Counter.dirty_keys()
        assert {:ok, _count} = Flusher.flush()
        assert Storage.load_counter(ctx.tenant, :ai_generations, ctx.period) == nil
      end)
    end

    test "I08 track/4 with durable: true raises for an events-source feature and writes no row",
         ctx do
      with_config(@events_source, fn ->
        assert_raise ArgumentError, fn ->
          AuroraMeter.track(ctx.tenant, :ai_generations, 1, durable: true)
        end
      end)

      assert event_rows(ctx.tenant) == 0
      assert Counter.base({ctx.tenant, :ai_generations, ctx.period}) == nil
    end

    test "I08 reserve/2 and reserve/3 raise for an events-source feature and write nothing",
         ctx do
      key = {ctx.tenant, :ai_generations, ctx.period}

      with_config(@events_source, fn ->
        for call <- [
              fn -> AuroraMeter.reserve(ctx.tenant, :ai_generations) end,
              fn -> AuroraMeter.reserve(ctx.tenant, :ai_generations, 3) end
            ] do
          error = assert_raise ArgumentError, call

          assert error.message =~ ":ai_generations"
          assert error.message =~ "AuroraMeter.with_quota/4"
          assert error.message =~ "AuroraMeter.check/2"
        end

        assert Counter.base(key) == nil
        refute key in Counter.dirty_keys()
      end)
    end

    test "track/4 and reserve/3 still work for a buffered feature and for one in durable_features",
         ctx do
      assert AuroraMeter.track(ctx.tenant, :ai_generations, 2) == :ok
      assert AuroraMeter.reserve(ctx.tenant, :ai_generations, 3) == :ok
      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 5

      with_config([{:aurora_meter, :durable_features, [:ai_generations]}], fn ->
        assert AuroraMeter.track(ctx.tenant, :ai_generations, 1) == :ok
      end)

      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 6
      assert event_rows(ctx.tenant) == 1
    end

    test "every read stays open for an events-source feature", ctx do
      # The guards are on the two writers that reach `pending_flush`. Nothing
      # that only reads is touched: a dashboard, a quota panel and an
      # entitlement check all keep working, because they read the ETS row the
      # projection maintains.
      AuroraMeter.subscribe(ctx.tenant, :free)

      with_config(@events_source, fn ->
        assert {:ok, _event, :inserted} =
                 AuroraMeter.record(ctx.tenant, :ai_generations, 7,
                   id: "reads",
                   occurred_at: ctx.at
                 )

        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 7
        assert AuroraMeter.usage_all(ctx.tenant) == %{ai_generations: 7}
        assert AuroraMeter.check(ctx.tenant, :ai_generations) == :ok
        assert AuroraMeter.allowed?(ctx.tenant, :ai_generations)
        assert AuroraMeter.entitled?(ctx.tenant, :ai_generations)
        assert AuroraMeter.remaining(ctx.tenant, :ai_generations) == 43
        assert AuroraMeter.quota(ctx.tenant, :ai_generations).used == 7
      end)
    end
  end

  describe "flush isolation" do
    test "I08 a thousand recorded events reach no flush batch, no counter row and no reporter read",
         ctx do
      {:ok, _drained} = Flusher.flush()

      with_config(@events_source, fn ->
        # Warm the key first: `Counter.apply_projection/2` skips a cold key on
        # purpose, and a test that never warmed it would prove only that a
        # projection which did not happen cannot be flushed.
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

        for batch <- 0..1 do
          elements =
            for n <- 1..500 do
              %{
                tenant: ctx.tenant,
                feature: :ai_generations,
                quantity: 1,
                id: "iso-#{batch}-#{n}",
                occurred_at: ctx.at
              }
            end

          assert {:ok, results} = AuroraMeter.record_batch(elements)
          assert length(results) == 500
        end

        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 1000

        batch = Store.snapshot_flush_batch()

        assert counters_for(batch, ctx.tenant) == [],
               "a projected quantity reached the flush batch"

        assert history_for(batch, ctx.tenant) == [],
               "a projected quantity reached the day-history half of the flush batch"

        assert {:ok, _count} = Flusher.flush()

        # The end of the chain, asserted in core so that a change to the
        # projection breaks a core test rather than a Pro one. This is the exact
        # call `AuroraMeter.Pro.UsageReporter.report_one/5` makes, and `|| 0` is
        # what it does with the nil.
        assert Storage.load_counter(ctx.tenant, :ai_generations, ctx.period) == nil
        assert (Storage.load_counter(ctx.tenant, :ai_generations, ctx.period) || 0) == 0

        assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 1000
      end)
    end

    test "I08 one flush writes the buffered feature and not the events-source one", ctx do
      {:ok, _drained} = Flusher.flush()

      with_config(@events_source, fn ->
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0
        assert AuroraMeter.track(ctx.tenant, :requests, 5) == :ok

        assert {:ok, _event, :inserted} =
                 AuroraMeter.record(ctx.tenant, :ai_generations, 7,
                   id: "mixed",
                   occurred_at: ctx.at
                 )

        batch = Store.snapshot_flush_batch()

        assert [%{feature: :requests, delta: 5}] = counters_for(batch, ctx.tenant)
        assert [%{feature: :requests, delta: 5}] = history_for(batch, ctx.tenant)

        assert {:ok, _count} = Flusher.flush()

        assert Storage.load_counter(ctx.tenant, :requests, ctx.period) == 5
        assert Storage.load_counter(ctx.tenant, :ai_generations, ctx.period) == nil
        assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 7
        assert Events.total(ctx.tenant, :requests, ctx.period) == 0
      end)
    end
  end

  describe "with_quota over an events-source feature" do
    test "I03 with_quota releases its reservation on success and leaves the recorded quantity",
         ctx do
      key = {ctx.tenant, :ai_generations, ctx.period}
      {:ok, _drained} = Flusher.flush()

      with_config(@events_source, fn ->
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

        assert {:ok, :done} =
                 AuroraMeter.with_quota(ctx.tenant, :ai_generations, 10, fn ->
                   # Mid-callback the estimate is held, which is the point of
                   # the gate: another caller sees 10 in use.
                   assert [{^key, 10, 0, _gossip, 0, 10}] = row(key)

                   assert {:ok, _event, :inserted} =
                            AuroraMeter.record(ctx.tenant, :ai_generations, 3,
                              id: "in-callback",
                              occurred_at: ctx.at
                            )

                   :done
                 end)

        # +10 and +3, then -10: the net is the recorded quantity, `reserved` is
        # back to zero, and `pending_flush` was never written.
        assert [{^key, 3, 0, _gossip, 0, 0}] = row(key)
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 3
        assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 3

        refute key in Counter.dirty_keys()
        assert mine(Store.snapshot_flush_batch(), ctx.tenant) == []
        assert {:ok, _count} = Flusher.flush()
        assert Storage.load_counter(ctx.tenant, :ai_generations, ctx.period) == nil
      end)
    end

    test "I03 with_quota over an events-source feature bills nothing when the callback records nothing",
         ctx do
      key = {ctx.tenant, :ai_generations, ctx.period}
      {:ok, _drained} = Flusher.flush()

      with_config(@events_source, fn ->
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

        assert {:ok, :nothing} =
                 AuroraMeter.with_quota(ctx.tenant, :ai_generations, 4, fn -> :nothing end)

        assert [{^key, 0, 0, _gossip, 0, 0}] = row(key)
        assert mine(Store.snapshot_flush_batch(), ctx.tenant) == []
        assert {:ok, _count} = Flusher.flush()
        assert Storage.load_counter(ctx.tenant, :ai_generations, ctx.period) == nil
        assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 0
      end)
    end

    test "I03 with_quota over an events-source feature releases on a raise, a throw and an exit",
         ctx do
      key = {ctx.tenant, :ai_generations, ctx.period}

      with_config(@events_source, fn ->
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

        assert_raise RuntimeError, fn ->
          AuroraMeter.with_quota(ctx.tenant, :ai_generations, 2, fn -> raise "boom" end)
        end

        assert [{^key, 0, 0, _g1, 0, 0}] = row(key)

        catch_throw(
          AuroraMeter.with_quota(ctx.tenant, :ai_generations, 2, fn -> throw(:nope) end)
        )

        assert [{^key, 0, 0, _g2, 0, 0}] = row(key)

        catch_exit(
          AuroraMeter.with_quota(ctx.tenant, :ai_generations, 2, fn -> exit(:timeout) end)
        )

        assert [{^key, 0, 0, _g3, 0, 0}] = row(key)
        refute key in Counter.dirty_keys()
      end)
    end

    test "I04 with_quota over an events-source feature admits exactly the limit of concurrent callers",
         ctx do
      # Admission control is about what is in flight at once, so the callers
      # have to be in flight at once. A cumulative version of this test would
      # assert the wrong thing for an events source: a released reservation
      # returns its capacity, and a caller that consumed nothing is not supposed
      # to have used any.
      AuroraMeter.subscribe(ctx.tenant, :free)
      limit = 50
      ref = make_ref()
      parent = self()

      with_config(@events_source, fn ->
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

        tasks =
          for _ <- 1..(limit + 5) do
            Task.async(fn ->
              AuroraMeter.with_quota(ctx.tenant, :ai_generations, fn ->
                send(parent, {:inside, ref, self()})

                receive do
                  {:release, ^ref} -> :done
                after
                  20_000 -> raise "the release never arrived"
                end
              end)
            end)
          end

        # Exactly `limit` callbacks report in, and no more: while all fifty units
        # are held, a fifty-first caller cannot be admitted.
        pids = collect_inside(ref, limit, [])
        refute_receive {:inside, ^ref, _fifty_first}, 500

        # A task still running is one blocked inside its callback, so it was
        # admitted; a task that has finished was refused.
        settled = Task.yield_many(tasks, 2_000)
        admitted = for {task, nil} <- settled, do: task
        refused = for {_task, {:ok, result}} <- settled, do: result

        # Release before asserting. `Task.yield_many/2` has already consumed the
        # replies of the refused tasks, so only the admitted ones may be awaited
        # (awaiting a yielded task waits for a message that has been taken), and
        # an assertion that fails while fifty tasks are still blocked would kill
        # them through the links `Task.async/1` created.
        Enum.each(pids, &send(&1, {:release, ref}))
        done = Task.await_many(admitted, 20_000)

        assert length(admitted) == limit
        assert refused == List.duplicate({:error, :limit_exceeded}, 5)
        assert done == List.duplicate({:ok, :done}, limit)

        # Nothing was recorded, so nothing is billable and the gate is open
        # again. That is the honest consequence of a reservation that is
        # admission control only.
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0
        assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 0
      end)
    end

    test "I03 a killed with_quota caller over an events-source feature bills nothing", ctx do
      key = {ctx.tenant, :ai_generations, ctx.period}
      ref = make_ref()
      parent = self()

      with_config(@events_source, fn ->
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

        pid =
          spawn(fn ->
            AuroraMeter.with_quota(ctx.tenant, :ai_generations, 6, fn ->
              send(parent, {:inside, ref, self()})
              Process.sleep(:infinity)
            end)
          end)

        assert_receive {:inside, ^ref, ^pid}, 5_000
        monitor = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000

        # The documented limit, asserted rather than wished away: a brutal kill
        # runs no `after` block, so the reservation stays in this node's ETS row
        # until the Store is rebuilt or the period rolls over. It is a local
        # admission-control leak and never a charge, which is the half that
        # matters.
        assert [{^key, 6, 0, _gossip, 0, 6}] = row(key),
               "a killed caller is expected to leave value=6 and reserved=6 on this node"

        refute key in Counter.dirty_keys()
        assert mine(Store.snapshot_flush_batch(), ctx.tenant) == []
        assert {:ok, _count} = Flusher.flush()
        assert Storage.load_counter(ctx.tenant, :ai_generations, ctx.period) == nil
        assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 0
      end)
    end
  end

  describe "projection, seeding and the cluster" do
    test "a cold read of an events-source feature seeds from the durable total", ctx do
      with_config(@events_source, fn ->
        for n <- 1..4 do
          assert {:ok, _event, :inserted} =
                   AuroraMeter.record(ctx.tenant, :ai_generations, 5,
                     id: "seed-#{n}",
                     occurred_at: ctx.at
                   )
        end

        total = Events.total(ctx.tenant, :ai_generations, ctx.period)
        assert total == 20

        AuroraMeter.Test.reset!()
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == total
      end)
    end

    test "an events-source feature has no day history", ctx do
      # Deliberate, not an oversight. A projected quantity in
      # `aurora_meter_history` would feed the Pro day rollup from the same units
      # the outbox exports, which is the double count this unit exists to
      # prevent. `AuroraMeter.Events.stream/2` is the durable series.
      with_config(@events_source, fn ->
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

        for n <- 1..10 do
          assert {:ok, _event, :inserted} =
                   AuroraMeter.record(ctx.tenant, :ai_generations, 1,
                     id: "hist-#{n}",
                     occurred_at: ctx.at
                   )
        end

        assert {:ok, _count} = Flusher.flush()

        points = AuroraMeter.history(ctx.tenant, :ai_generations, days: 7)
        assert length(points) == 7
        assert Enum.map(points, & &1.value) == List.duplicate(0, 7)
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 10
      end)
    end

    test "I05 a peer's projected delta moves this node's value and a cold reseed corrects it",
         ctx do
      with_config(@events_source, fn ->
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

        assert {:ok, _event, :inserted} =
                 AuroraMeter.record(ctx.tenant, :ai_generations, 2,
                   id: "node-a",
                   occurred_at: ctx.at
                 )

        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 2

        # Node B recorded 9 of its own and gossiped the projected delta. The
        # durable total is shared state, so there is no convergence gap: the
        # gossip is a shortcut to a number this node could also read.
        assert AuroraMeter.Test.simulate_node(:b@node, [{ctx.tenant, :ai_generations, 9}]) == :ok
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 11

        # The peer's 9 is gossip, not a commit, so the database still holds this
        # node's 2. A cold reseed reads the durable total and corrects the view.
        AuroraMeter.Test.reset!()
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 2
      end)
    end

    test "I05 a peer's totals announcement never rebases an events-source key", ctx do
      # Two mechanisms hold here and the test exercises the second, because the
      # first cannot be exercised at all.
      #
      # The first is that `AuroraMeter.Cluster` only announces the keys a node
      # put in a flush batch, and an events-source key is never in one (asserted
      # above), so no such announcement can exist. Proving a message is never
      # sent means proving the flush batch is empty, which is what the flush
      # isolation tests do.
      #
      # The second is what happens if one arrives anyway. `Cluster`'s totals
      # branch only moves a key forward (`total >= base`), and a peer's total
      # for an events-source key is whatever `aurora_meter_counters` holds,
      # which is nothing. So the announcement is refused rather than applied.
      # Without that guard `Counter.rebase/3` would set `value` to
      # `total + pending_flush + reserved`, which here is 0, and the projected
      # quantity would vanish from this node's view.
      key = {ctx.tenant, :ai_generations, ctx.period}

      with_config(@events_source, fn ->
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

        assert {:ok, _event, :inserted} =
                 AuroraMeter.record(ctx.tenant, :ai_generations, 12,
                   id: "not-rebased",
                   occurred_at: ctx.at
                 )

        assert Counter.base(key) == 12

        assert Cluster.apply(:totals, :b@node, [{key, 0}]) == :ok

        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 12
        assert Counter.base(key) == 12
      end)
    end
  end

  describe "export eligibility" do
    test "record/4 on a buffered feature stores the fact and marks the export intent ineligible",
         ctx do
      # Recording a late or corrected fact for a buffered feature is allowed and
      # the fact is kept. Exporting it is not: a reporter already stages the
      # counter delta for that feature, so the provider would be told about the
      # same usage twice. The item is quarantined with the reason rather than
      # dropped, so an operator can see it (Pro, 04b).
      with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        assert {:ok, event, :inserted} =
                 AuroraMeter.record(ctx.tenant, :ai_generations, 4,
                   id: "buffered-fact",
                   occurred_at: ctx.at
                 )

        assert [%{event: recorded, eligibility: {:ineligible, :feature_buffered}}] =
                 RecordingOutbox.items()

        assert recorded.event_id == event.event_id
        assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 4
        assert event_rows(ctx.tenant) == 1
      end)
    end

    test "record/4 on an events-source feature marks the export intent eligible", ctx do
      # The negative control for the rule above: the same call, the same outbox,
      # one configuration key apart.
      with_config(
        [
          {:aurora_meter, :events_outbox, RecordingOutbox},
          {:aurora_meter, :feature_sources, %{ai_generations: :events}}
        ],
        fn ->
          assert {:ok, _event, :inserted} =
                   AuroraMeter.record(ctx.tenant, :ai_generations, 4,
                     id: "events-fact",
                     occurred_at: ctx.at
                   )

          assert [%{eligibility: :eligible}] = RecordingOutbox.items()
        end
      )
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp row(key), do: :ets.lookup(Store.counters_table(), key)

  # A flush batch is two halves, and both matter: `counters` becomes
  # `aurora_meter_counters`, which is what a reporter bills, and `history`
  # becomes `aurora_meter_history`, which is what the Pro day rollup reads.
  defp counters_for(batch, tenant), do: half(batch, :counters, tenant)
  defp history_for(batch, tenant), do: half(batch, :history, tenant)

  defp half(nil, _which, _tenant), do: []

  defp half(batch, which, tenant) do
    batch |> Map.fetch!(which) |> Enum.filter(&(&1.tenant_key == tenant))
  end

  defp mine(batch, tenant), do: counters_for(batch, tenant) ++ history_for(batch, tenant)

  defp event_rows(tenant) do
    TestRepo.aggregate(from(e in Event, where: e.tenant_key == ^tenant), :count)
  end

  # Waits for exactly `n` callbacks to report that they are inside, rather than
  # draining whatever happens to have arrived: a task that yielded `nil` is one
  # this test is about to wait on, so failing to collect its pid would turn a
  # scheduling delay into a twenty second timeout with no explanation.
  defp collect_inside(_ref, 0, acc), do: acc

  defp collect_inside(ref, n, acc) do
    receive do
      {:inside, ^ref, pid} -> collect_inside(ref, n - 1, [pid | acc])
    after
      5_000 ->
        flunk("only #{length(acc)} of #{length(acc) + n} admitted callbacks reported in")
    end
  end

  defp occurrences(text, needle) do
    text |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
