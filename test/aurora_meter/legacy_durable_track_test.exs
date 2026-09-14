defmodule AuroraMeter.LegacyDurableTrackTest do
  @moduledoc """
  Build unit 03c: what `AuroraMeter.track(..., durable: true)` writes, and the
  three things it deliberately does not (lower-level invariant L-03c-3).

  This path is kept working and is deprecated. It predates caller identity, so
  it has none, and the honest expression of that is a fresh uuid per call: two
  identical calls write two rows. The tests below assert that rather than
  working around it, because a documented "no deduplication" that no test holds
  to is the kind of claim that quietly becomes false.

  The `track:` prefix on `event_id` and `attribution = "legacy_track"` are what
  separate these rows from recorded ones in every query, report and replay, and
  `AuroraMeter.record/4` refuses a caller id carrying the prefix so the two
  namespaces cannot meet.

  `async: false`: `AuroraMeter.track/4` writes the node-wide ETS tables, and the
  fault and configuration regions are node-wide too.
  """
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test.Config, only: [with_config: 2]
  import ExUnit.CaptureLog

  alias AuroraMeter.Counter
  alias AuroraMeter.Events
  alias AuroraMeter.Period
  alias AuroraMeter.Schema.Event
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.FaultStorage
  alias AuroraMeter.Test.RecordingOutbox

  setup do
    RecordingOutbox.start!()
    tenant = unique_tenant("legacy")
    {:ok, tenant: tenant, period: Period.current!(tenant).start}
  end

  describe "what a legacy durable row carries" do
    test "L-03c-3 a legacy durable track writes a track: event id and attribution legacy_track",
         ctx do
      assert AuroraMeter.track(ctx.tenant, :ai_generations, 3, durable: true) == :ok

      assert [event] = rows(ctx.tenant)
      assert String.starts_with?(event.event_id, "track:")
      assert {:ok, _uuid} = Ecto.UUID.cast(String.replace_prefix(event.event_id, "track:", ""))
      assert event.attribution == "legacy_track"
      assert event.kind == "usage"
      assert event.original_event_id == nil
      assert event.dimensions == %{}
      assert event.plan_id == nil
      assert event.plan_version == nil
      assert event.quantity == 3
      assert is_binary(event.payload_hash)
      assert byte_size(event.payload_hash) == 32
    end

    test "a legacy durable row carries the period the counter was bumped in", ctx do
      # The period is resolved once, by `AuroraMeter.track/4`, and passed down.
      # A second resolution inside the adapter could land on the other side of a
      # boundary from the increment the row accompanies.
      assert AuroraMeter.track(ctx.tenant, :ai_generations, 1, durable: true) == :ok

      assert [event] = rows(ctx.tenant)
      assert event.period_start == DateTime.truncate(ctx.period, :second)
      assert event.period_source == "calendar"
    end

    test "occurred_at is the write instant, because this path has no other one", ctx do
      assert AuroraMeter.track(ctx.tenant, :ai_generations, 1, durable: true) == :ok

      assert [event] = rows(ctx.tenant)
      assert event.occurred_at == event.inserted_at
    end

    test "L-03c-3 two identical legacy durable tracks write two rows", ctx do
      # Not a defect to be fixed here: `track/4` takes no caller identity, so
      # there is nothing to recognise a retry by. `AuroraMeter.record/4` is the
      # path where a retry is a duplicate.
      assert AuroraMeter.track(ctx.tenant, :ai_generations, 1, durable: true) == :ok
      assert AuroraMeter.track(ctx.tenant, :ai_generations, 1, durable: true) == :ok

      assert [first, second] = rows(ctx.tenant)
      assert first.event_id != second.event_id

      # Nor does the payload hash make the pair recognisable as a repeat. It
      # covers `occurred_at`, and on this path `occurred_at` is the write
      # instant, so two calls that a caller would call identical hash
      # differently. There is nothing in either row that says "this is the same
      # fact as that one", which is exactly the claim `record/4` exists to be
      # able to make and this path cannot.
      assert first.payload_hash != second.payload_hash
      assert first.feature == second.feature
      assert first.quantity == second.quantity

      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 2
    end

    test "L-03c-3 a legacy durable track writes no event total and calls no outbox", ctx do
      with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        assert AuroraMeter.track(ctx.tenant, :ai_generations, 4, durable: true) == :ok

        assert length(rows(ctx.tenant)) == 1
        assert RecordingOutbox.calls() == 0
        assert RecordingOutbox.items() == []
        assert totals(ctx.tenant) == []
        assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 0
      end)
    end

    test "L-03c-3 a recorded event for the same feature does write a total and an outbox item",
         ctx do
      # The negative control for the three negatives above: the same feature,
      # the same tenant, one call apart. If `insert_events/1` ever grew a
      # projection or an outbox call, this test would keep passing and the one
      # above would start failing, which is the right way round.
      with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        assert {:ok, _event, :inserted} =
                 AuroraMeter.record(ctx.tenant, :ai_generations, 4,
                   id: "control",
                   occurred_at: AuroraMeter.Clock.now()
                 )

        assert RecordingOutbox.calls() == 1
        assert [%{quantity: 4, events: 1}] = totals(ctx.tenant)
        assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 4
      end)
    end

    test "a durable_features entry writes the same row as durable: true", ctx do
      with_config([{:aurora_meter, :durable_features, [:ai_generations]}], fn ->
        assert AuroraMeter.track(ctx.tenant, :ai_generations, 2) == :ok
      end)

      assert [event] = rows(ctx.tenant)
      assert String.starts_with?(event.event_id, "track:")
      assert event.attribution == "legacy_track"
    end

    test "a legacy durable row satisfies every core version 8 constraint", ctx do
      # Version 8 promoted `event_id`, `payload_hash` and `occurred_at` to NOT
      # NULL and added `quantity > 0` and a metadata size bound. The test repo is
      # migrated to 8, so the assertion is that the insert happens at all: a
      # violation is a database error out of `track/4`, not a soft failure.
      assert AuroraMeter.track(ctx.tenant, :ai_generations, 1,
               durable: true,
               metadata: %{"request" => "abc", "nested" => %{"k" => 1}}
             ) == :ok

      assert [event] = rows(ctx.tenant)
      refute is_nil(event.event_id)
      refute is_nil(event.payload_hash)
      refute is_nil(event.occurred_at)
      assert event.quantity > 0
      assert event.metadata == %{"request" => "abc", "nested" => %{"k" => 1}}
      assert is_integer(event.seq)
    end

    test "a caller id beginning with track: or legacy: is refused by record/4", ctx do
      # Asserted from this side as well as 03b's, because it is what keeps the
      # two identity namespaces from meeting: a recorded event can never be
      # mistaken for a legacy row, whichever direction the confusion comes from.
      at = AuroraMeter.Clock.now()

      for prefix <- ["track:", "legacy:", "recurring:"] do
        assert {:error, {:invalid, errors}} =
                 AuroraMeter.record(ctx.tenant, :ai_generations, 1,
                   id: prefix <> "anything",
                   occurred_at: at
                 )

        assert {:id, :reserved_prefix} in errors
      end

      assert rows(ctx.tenant) == []
    end
  end

  describe "when the write fails" do
    test "a legacy durable write failure is logged with the tenant and the feature and re-raised",
         ctx do
      # The rescue adds the log line and nothing else. Swallowing the failure
      # would leave the ETS counter bumped and the caller believing the row
      # exists, which is worse than the exception it already had.
      log =
        capture_log(fn ->
          with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
            Faults.arm(:before_commit, :raise, when: &(&1.callback == :insert_events))

            assert_raise Faults.Injected, fn ->
              AuroraMeter.track(ctx.tenant, :ai_generations, 2, durable: true)
            end

            Faults.assert_fired!(:before_commit)
            Faults.disarm_all()
          end)
        end)

      assert log =~ "AuroraMeter durable event write failed"
      assert log =~ ctx.tenant
      assert log =~ ":ai_generations"

      # The counter moved and the row did not. That is the disagreement, stated
      # rather than hidden: the count will flush and the fact is gone.
      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 2
      assert rows(ctx.tenant) == []
    end

    test "a successful legacy durable write logs nothing", ctx do
      # The negative control for the rescue: the log line must come from the
      # failure and not from the path.
      log =
        capture_log(fn ->
          assert AuroraMeter.track(ctx.tenant, :ai_generations, 1, durable: true) == :ok
        end)

      refute log =~ "AuroraMeter durable event write failed"
      assert length(rows(ctx.tenant)) == 1
    end

    test "C14 a legacy durable write inside a host transaction rolls back with it while the ETS bump survives",
         ctx do
      # Known, documented and NOT fixed here. `AuroraMeter.track/4` bumps ETS and
      # then inserts, outside any transaction of its own. Inside a host
      # transaction the insert joins that transaction and disappears with it,
      # while the ETS increment survives and will flush. This test asserts the
      # behaviour so that it cannot change silently, and names the path that does
      # not have it.
      key = {ctx.tenant, :ai_generations, ctx.period}

      assert {:error, :host_changed_its_mind} =
               TestRepo.transaction(fn ->
                 assert AuroraMeter.track(ctx.tenant, :ai_generations, 5, durable: true) == :ok
                 TestRepo.rollback(:host_changed_its_mind)
               end)

      assert rows(ctx.tenant) == [], "the row rolled back with the host transaction"

      # `value` is 5 and `pending_flush` is 5: the increment survived and is
      # queued for the flusher, so this usage will reach `aurora_meter_counters`
      # with no event row to match it. `Counter.base/1` is 0 for the same
      # reason, which is the node saying it believes the database holds nothing
      # yet.
      assert [{^key, 5, 5, _gossip, 0, 0}] =
               :ets.lookup(AuroraMeter.Store.counters_table(), key)

      assert Counter.base(key) == 0
      assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 5

      # `AuroraMeter.record/4` is the path with no such window: its event, its
      # total and its export intent are one commit with the host's.
      assert {:error, :and_again} =
               TestRepo.transaction(fn ->
                 assert {:ok, _event, :inserted} =
                          AuroraMeter.record(ctx.tenant, :ai_generations, 5,
                            id: "rolled-back",
                            occurred_at: AuroraMeter.Clock.now()
                          )

                 TestRepo.rollback(:and_again)
               end)

      assert rows(ctx.tenant) == []
      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 0
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp rows(tenant) do
    TestRepo.all(from(e in Event, where: e.tenant_key == ^tenant, order_by: e.seq))
  end

  defp totals(tenant) do
    TestRepo.all(
      from(t in EventTotal,
        where: t.tenant_key == ^tenant,
        select: %{
          quantity: t.quantity,
          events: t.events
        }
      )
    )
  end
end
