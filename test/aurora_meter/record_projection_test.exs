defmodule AuroraMeter.RecordProjectionTest do
  @moduledoc """
  What a recorded event does to the in-memory view and to a host's own
  transaction (build unit 03b).

  I08 is the load-bearing one here and this unit is a contributor to it: a
  projected quantity must never reach the flush path, because
  `aurora_meter_counters` is the table Aurora Meter Pro's reporter bills from,
  and a durable event that also arrives there is the same usage charged twice.
  03c owns the invariant; this module proves the half of it that this unit
  could break.

  Not `AuroraMeter.DataCase`: a host transaction that rolls back is a
  durability claim, and the sandbox's own transaction would make the assertion
  read the connection that aborted.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Counter
  alias AuroraMeter.Event
  alias AuroraMeter.Events
  alias AuroraMeter.Flusher
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Storage
  alias AuroraMeter.Store
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.PeriodSources
  alias AuroraMeter.Test.RecordingOutbox
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    AuroraMeter.Test.reset!()
    :ok = RecordingOutbox.start!()
    tenant = AuroraMeter.Test.unique_tenant("projection")
    on_exit(fn -> Connections.cleanup!(tenant) end)

    own = Connections.checkout!()
    on_exit(fn -> if own, do: Sandbox.checkin(Connections.repo()) end)

    # The Flusher is a separate process with no connection of its own on a
    # non-sandbox module, so the two tests that drive a real flush have to let
    # it onto this one. The allowance is released when this process exits.
    Sandbox.allow(Connections.repo(), self(), Process.whereis(Flusher))

    %{tenant: tenant, at: DateTime.utc_now(), period: AuroraMeter.period(tenant).start}
  end

  defp repo, do: Connections.repo()

  defp event_count(tenant) do
    repo().aggregate(from(e in AuroraMeter.Schema.Event, where: e.tenant_key == ^tenant), :count)
  end

  defp totals(tenant) do
    repo().all(
      from(t in EventTotal, where: t.tenant_key == ^tenant, select: map(t, [:quantity, :events]))
    )
  end

  describe "the sandbox and in_transaction?/0" do
    test "03b verify in_transaction?/0 under the sandbox", _ctx do
      # docs/evidence/v1/phase-03/03b-in-transaction.md. The build document
      # warned that a sandbox connection might report `true` with no host
      # transaction, which would make every sandbox-based test take the
      # conditional path. Measured on ecto_sql 3.14.0 it does not:
      # `Ecto.Adapters.SQL.in_transaction?/1` reads the Ecto-side connection in
      # the process dictionary, and the sandbox's own BEGIN is issued inside the
      # connection process rather than through `Ecto.Adapters.SQL.transaction/3`.
      # This is the assertion that would fail if a future ecto_sql changed it.
      refute Storage.Ecto.host_transaction?()

      # In a process of its own, because this one already owns a non-sandbox
      # connection from `setup`.
      task =
        Task.async(fn ->
          pid = Sandbox.start_owner!(Connections.repo(), shared: false)

          try do
            refute Storage.Ecto.host_transaction?(),
                   "a sandbox checkout reports a host transaction; " <>
                     "host_transaction?/0 needs a carve-out"

            Connections.repo().transaction(fn ->
              assert Storage.Ecto.host_transaction?()
            end)

            refute Storage.Ecto.host_transaction?()
          after
            Sandbox.stop_owner(pid)
          end
        end)

      Task.await(task, 15_000)
      refute Storage.Ecto.host_transaction?()
    end
  end

  describe "a host's own transaction" do
    test "record inside a host transaction returns durability: :conditional and publishes nothing before after_commit/1",
         ctx do
      Phoenix.PubSub.subscribe(AuroraMeter.Config.pubsub(), Broadcaster.topic(ctx.tenant))

      {:ok, event} =
        repo().transaction(fn ->
          assert {:ok, event, :inserted} =
                   AuroraMeter.record(ctx.tenant, :ai_generations, 3,
                     id: "conditional",
                     occurred_at: ctx.at
                   )

          assert event.durability == :conditional
          event
        end)

      refute_received {:aurora_meter, :event, _payload}
      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

      assert Events.after_commit([event]) == :ok
      assert_received {:aurora_meter, :event, %{event_id: "conditional", quantity: 3}}
    end

    test "I06 an outer host transaction rollback leaves no event, no totals delta, no outbox item and no ETS delta",
         ctx do
      TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        Phoenix.PubSub.subscribe(AuroraMeter.Config.pubsub(), Broadcaster.topic(ctx.tenant))

        assert {:error, :host_said_no} =
                 repo().transaction(fn ->
                   assert {:ok, %Event{durability: :conditional}, :inserted} =
                            AuroraMeter.record(ctx.tenant, :ai_generations, 11,
                              id: "rolled-back",
                              occurred_at: ctx.at
                            )

                   repo().rollback(:host_said_no)
                 end)

        assert event_count(ctx.tenant) == 0
        assert totals(ctx.tenant) == []
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0
        refute_received {:aurora_meter, :event, _payload}

        # The outbox was called inside the host's transaction, so its write (if
        # it had made one) rolled back with everything else. The recorder is an
        # Agent and therefore outside the transaction, which is exactly why a
        # real implementation must use the repo it is handed.
        assert length(RecordingOutbox.items()) == 1
      end)
    end

    test "I06 an outer host transaction commit plus after_commit/1 hydrates ETS and publishes one message",
         ctx do
      Phoenix.PubSub.subscribe(AuroraMeter.Config.pubsub(), Broadcaster.topic(ctx.tenant))

      # Warm the key first, so the projection has somewhere to land. A cold key
      # is skipped on purpose: it seeds from durable state on its first read.
      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

      {:ok, event} =
        repo().transaction(fn ->
          {:ok, event, :inserted} =
            AuroraMeter.record(ctx.tenant, :ai_generations, 6,
              id: "committed",
              occurred_at: ctx.at
            )

          event
        end)

      assert event_count(ctx.tenant) == 1
      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

      assert Events.after_commit(event) == :ok
      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 6

      assert_received {:aurora_meter, :event, %{event_id: "committed"}}
      refute_received {:aurora_meter, :event, _payload}
    end
  end

  describe "I08 the projection never reaches the flush path" do
    test "I08 a projected event never appears in a flush batch", ctx do
      TestConfig.with_config(
        [{:aurora_meter, :feature_sources, %{ai_generations: :events}}],
        fn ->
          # Warm the key, so `apply_projection/2` really writes rather than
          # reporting the key cold and skipping.
          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

          for batch <- 0..1 do
            elements =
              for n <- 1..500 do
                %{
                  tenant: ctx.tenant,
                  feature: :ai_generations,
                  quantity: 1,
                  id: "flush-#{batch}-#{n}",
                  occurred_at: ctx.at
                }
              end

            assert {:ok, results} = AuroraMeter.record_batch(elements)
            assert length(results) == 500
          end

          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 1000

          batch = Store.snapshot_flush_batch()

          entries =
            case batch do
              nil -> []
              %{counters: counters} -> Enum.filter(counters, &(&1.tenant_key == ctx.tenant))
            end

          assert entries == [],
                 "a projected quantity reached the flush batch: #{inspect(entries)}"

          {:ok, _n} = Flusher.flush()

          assert Storage.load_counter(ctx.tenant, :ai_generations, ctx.period) == nil,
                 "a projected quantity reached aurora_meter_counters, which Pro bills from"

          assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 1000
        end
      )
    end

    test "I08 apply_projection writes value and gossip but never pending_flush or dirty", ctx do
      key = {ctx.tenant, :ai_generations, ctx.period}

      # Warm it through the ordinary read path, then clear what that marked.
      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0
      Counter.clear_dirty(key)
      Counter.clear_touched(key)

      assert Counter.apply_projection(key, 4) == :ok

      refute key in Counter.dirty_keys()
      assert key in Counter.touched_keys()
      assert Counter.take_pending(key, :flush) == 0
      assert Counter.take_pending(key, :gossip) == 4
      assert Counter.value(ctx.tenant, :ai_generations, ctx.period) == 4
    end

    test "apply_projection skips a cold key", ctx do
      assert Counter.apply_projection({ctx.tenant, :never_touched, ctx.period}, 5) == :cold
    end
  end

  describe "hydration" do
    test "the projection hydrates the current period only", ctx do
      previous = DateTime.add(ctx.period, -1, :day)

      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

      assert {:ok, event, :inserted} =
               AuroraMeter.record(ctx.tenant, :ai_generations, 8,
                 id: "last-period",
                 occurred_at: previous
               )

      refute event.period_start == ctx.period

      # The current period's counter did not move, and no ETS row was created
      # for the old period key either: hydrating arbitrary past periods would
      # grow the table without bound as backfills and late facts arrive.
      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0
      assert Counter.base({ctx.tenant, :ai_generations, event.period_start}) == nil

      # The durable total is still authoritative for that period.
      assert Events.total(ctx.tenant, :ai_generations, event.period_start) == 8
    end

    test "usage/2 for an events-source feature after reset!/0 equals Events.total/3", ctx do
      TestConfig.with_config(
        [{:aurora_meter, :feature_sources, %{ai_generations: :events}}],
        fn ->
          for n <- 1..5 do
            assert {:ok, _event, :inserted} =
                     AuroraMeter.record(ctx.tenant, :ai_generations, 3,
                       id: "cold-#{n}",
                       occurred_at: ctx.at
                     )
          end

          total = Events.total(ctx.tenant, :ai_generations, ctx.period)
          assert total == 15

          AuroraMeter.Test.reset!()

          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == total
        end
      )
    end

    test "a buffered feature still seeds from the counter table, not from event totals", ctx do
      # The seeding indirection must not change what a buffered feature does:
      # 08c's benchmark compares this path and 03c owns the decision.
      AuroraMeter.track(ctx.tenant, :ai_generations, 4)
      {:ok, _n} = Flusher.flush()

      assert {:ok, _event, :inserted} =
               AuroraMeter.record(ctx.tenant, :ai_generations, 100,
                 id: "not-in-the-counter",
                 occurred_at: ctx.at
               )

      AuroraMeter.Test.reset!()

      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 4
    end
  end

  describe "post-commit effects are views, not the fact" do
    test "PubSub delivers one event message per inserted event and none per duplicate", ctx do
      Phoenix.PubSub.subscribe(AuroraMeter.Config.pubsub(), Broadcaster.topic(ctx.tenant))

      assert {:ok, _event, :inserted} =
               AuroraMeter.record(ctx.tenant, :ai_generations, 2, id: "pub", occurred_at: ctx.at)

      assert_received {:aurora_meter, :event, payload}

      assert payload == %{
               tenant_key: ctx.tenant,
               feature: :ai_generations,
               event_id: "pub",
               quantity: 2,
               period_start: ctx.period,
               kind: :usage
             }

      assert {:ok, _event, :duplicate} =
               AuroraMeter.record(ctx.tenant, :ai_generations, 2, id: "pub", occurred_at: ctx.at)

      refute_received {:aurora_meter, :event, _payload}
    end

    test "a failing PubSub does not turn a committed event into an error", ctx do
      TestConfig.with_config([{:aurora_meter, :pubsub, :no_such_pubsub_server}], fn ->
        assert {:ok, event, :inserted} =
                 AuroraMeter.record(ctx.tenant, :ai_generations, 1,
                   id: "pubsub-down",
                   occurred_at: ctx.at
                 )

        assert event.durability == :durable
      end)

      assert event_count(ctx.tenant) == 1
    end

    test "a raising projection does not turn a committed event into an error", ctx do
      TestConfig.with_config(
        [{:aurora_meter, :period_source, PeriodSources.FutureWindow}],
        fn ->
          assert {:ok, event, :inserted} =
                   AuroraMeter.record(ctx.tenant, :ai_generations, 1,
                     id: "projection-down",
                     occurred_at: ctx.at
                   )

          assert event.attribution == :unresolved
        end
      )

      assert event_count(ctx.tenant) == 1
      assert [%{quantity: 1, events: 1}] = totals(ctx.tenant)
    end
  end
end
