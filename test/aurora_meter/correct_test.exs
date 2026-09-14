defmodule AuroraMeter.CorrectTest do
  @moduledoc """
  The contract of `AuroraMeter.correct/4`: the cumulative bound, the step order
  that makes a bounded correction idempotent, and everything a correction
  inherits from the fact it reduces (build unit 03e, invariant **I09**).

  Everything here is a single-connection fact, so it runs on the sandbox. The
  half of I09 that needs real contention (twelve correctors of one original, and
  a corrector killed on either side of the commit) lives in
  `AuroraMeter.CorrectConcurrencyTest`, and the sandbox would make every
  assertion there pass on code with no lock at all.
  """
  use AuroraMeter.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Counter
  alias AuroraMeter.Event
  alias AuroraMeter.Events
  alias AuroraMeter.Period
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Store
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.IncapableStorage
  alias AuroraMeter.Test.PeriodSources
  alias AuroraMeter.Test.RecordingOutbox

  setup do
    AuroraMeter.Test.reset!()
    :ok = RecordingOutbox.start!()
    tenant = unique_tenant("correct")
    at = ~U[2026-09-10 12:00:00.000000Z]
    %{tenant: tenant, at: at, period: AuroraMeter.period(tenant).start}
  end

  defp record(ctx, id, quantity, opts \\ []) do
    feature = Keyword.get(opts, :feature, :ai_generations)

    AuroraMeter.record(ctx.tenant, feature, quantity,
      id: id,
      occurred_at: Keyword.get(opts, :occurred_at, ctx.at),
      dimensions: Keyword.get(opts, :dimensions, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp rows(tenant) do
    TestRepo.all(
      from(e in AuroraMeter.Schema.Event,
        where: e.tenant_key == ^tenant,
        order_by: [asc: e.seq],
        select:
          map(e, [
            :event_id,
            :quantity,
            :kind,
            :original_event_id,
            :feature,
            :period_start,
            :period_source,
            :occurred_at,
            :attribution,
            :plan_id,
            :plan_version,
            :dimensions
          ])
      )
    )
  end

  defp totals(tenant) do
    TestRepo.all(
      from(t in EventTotal,
        where: t.tenant_key == ^tenant,
        order_by: [asc: t.period_start],
        select: map(t, [:feature, :period_start, :quantity, :events])
      )
    )
  end

  # -- the step order, which is the whole unit ------------------------------

  describe "the cumulative bound" do
    test "I09 a correction reduces the projected total by its magnitude", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)

      assert {:ok, %Event{} = correction, :inserted} =
               AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")

      assert correction.kind == :correction
      assert correction.quantity == 3
      assert correction.original_event_id == "base"

      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 7
      assert [%{quantity: 7, events: 2}] = totals(ctx.tenant)
    end

    test "I09 cumulative corrections cannot exceed the original", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 6, id: "fix-1")

      assert AuroraMeter.correct(ctx.tenant, "base", 5, id: "fix-2") ==
               {:error, {:invalid, [quantity: :exceeds_original]}}

      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 4
      assert length(rows(ctx.tenant)) == 2
    end

    test "I09 a full reversal then a further correction is rejected", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 10, id: "fix-all")

      assert AuroraMeter.correct(ctx.tenant, "base", 1, id: "fix-more") ==
               {:error, {:invalid, [quantity: :exceeds_original]}}

      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 0
      assert [%{quantity: 0, events: 2}] = totals(ctx.tenant)
    end

    test "I09 a duplicate correction id is idempotent", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)

      assert {:ok, first, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")
      assert {:ok, second, :duplicate} = AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")

      assert second.id == first.id
      assert length(rows(ctx.tenant)) == 2
      assert [%{quantity: 7, events: 2}] = totals(ctx.tenant)

      # One insert, one delta, one intent. A duplicate stages nothing, and no
      # outbox is configured here at all.
      assert RecordingOutbox.items() == []
    end

    test "I09 a duplicate correction id is idempotent even when the original is already fully corrected",
         ctx do
      # THE step-order test. With the bound evaluated before the duplicate
      # check, this retry sees its own committed row inside the cumulative sum
      # and is refused `exceeds_original`, which would make every retry of a
      # correct correction fail. `docs/evidence/v1/phase-03/03e-step-order.md`
      # records the observed failure with the order inverted.
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 10, id: "fix-all")

      assert {:ok, %Event{quantity: 10}, :duplicate} =
               AuroraMeter.correct(ctx.tenant, "base", 10, id: "fix-all")

      assert length(rows(ctx.tenant)) == 2
      assert [%{quantity: 0, events: 2}] = totals(ctx.tenant)
    end
  end

  # -- identity -------------------------------------------------------------

  describe "identity" do
    test "I07 a correction id reused with a different magnitude conflicts", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")

      assert {:error, {:conflict, existing}} =
               AuroraMeter.correct(ctx.tenant, "base", 4, id: "fix")

      assert existing.quantity == 3
      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 7
      assert length(rows(ctx.tenant)) == 2
    end

    test "I07 a correction id reused with different metadata conflicts", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)

      assert {:ok, _c, :inserted} =
               AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix", metadata: %{"why" => "a"})

      assert {:error, {:conflict, existing}} =
               AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix", metadata: %{"why" => "b"})

      assert existing.metadata == %{"why" => "a"}
    end

    test "I09 a correction to a correction is rejected", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")

      assert AuroraMeter.correct(ctx.tenant, "fix", 1, id: "fix-the-fix") ==
               {:error, {:invalid, [original: :is_correction]}}

      assert length(rows(ctx.tenant)) == 2
    end

    test "a correction of a missing original returns not_found", ctx do
      assert AuroraMeter.correct(ctx.tenant, "no-such-event", 1, id: "fix") ==
               {:error, {:not_found, :original}}
    end

    test "an original is per tenant: correcting another tenant's event is not found", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      other = unique_tenant("correct")

      assert AuroraMeter.correct(other, "base", 1, id: "fix") ==
               {:error, {:not_found, :original}}
    end
  end

  # -- validation, before any database call ---------------------------------

  describe "validation" do
    test "a correction rejects zero, a negative and a float magnitude", ctx do
      for bad <- [0, -1, 1.5] do
        assert {:error, {:invalid, errors}} =
                 AuroraMeter.correct(ctx.tenant, "base", bad, id: "f")

        assert {:quantity, :not_a_positive_integer} in errors
      end
    end

    test "a correction rejects the internal :remaining magnitude", ctx do
      # `:remaining` is what `replace/4` passes down; a caller who reaches for
      # it gets the same answer as any other non-integer, not a full reversal.
      assert {:error, {:invalid, errors}} =
               AuroraMeter.correct(ctx.tenant, "base", :remaining, id: "f")

      assert {:quantity, :not_a_positive_integer} in errors
    end

    test "a correction rejects dimensions: and occurred_at:", ctx do
      assert {:error, {:invalid, errors}} =
               AuroraMeter.correct(ctx.tenant, "base", 1, id: "f", dimensions: %{"a" => "b"})

      assert {:dimensions, :not_supported_on_correction} in errors

      assert {:error, {:invalid, errors}} =
               AuroraMeter.correct(ctx.tenant, "base", 1, id: "f", occurred_at: ctx.at)

      assert {:occurred_at, :not_supported_on_correction} in errors
    end

    test "a correction rejects a missing, oversized or reserved id", ctx do
      assert {:error, {:invalid, errors}} = AuroraMeter.correct(ctx.tenant, "base", 1, [])
      assert {:id, :missing} in errors

      long = String.duplicate("x", 129)
      assert {:error, {:invalid, errors}} = AuroraMeter.correct(ctx.tenant, "base", 1, id: long)
      assert {:id, :too_long} in errors

      assert {:error, {:invalid, errors}} =
               AuroraMeter.correct(ctx.tenant, "base", 1, id: "legacy:x")

      assert {:id, :reserved_prefix} in errors
    end

    test "a correction rejects a missing or oversized original id", ctx do
      assert {:error, {:invalid, errors}} = AuroraMeter.correct(ctx.tenant, nil, 1, id: "f")
      assert {:original, :missing} in errors

      long = String.duplicate("x", 129)
      assert {:error, {:invalid, errors}} = AuroraMeter.correct(ctx.tenant, long, 1, id: "f")
      assert {:original, :too_long} in errors
    end

    test "a correction rejects metadata that is too large or not JSON", ctx do
      assert {:error, {:invalid, errors}} =
               AuroraMeter.correct(ctx.tenant, "base", 1,
                 id: "f",
                 metadata: %{"a" => String.duplicate("x", 17_000)}
               )

      assert {:metadata, :too_large} in errors

      assert {:error, {:invalid, errors}} =
               AuroraMeter.correct(ctx.tenant, "base", 1, id: "f", metadata: %{a: 1})

      assert {:metadata, :non_string_key} in errors
    end
  end

  # -- inheritance ----------------------------------------------------------

  describe "what a correction inherits" do
    test "L-03e-2 a correction inherits the original's feature, period, period source and plan attribution",
         ctx do
      # The original is attributed to a PREVIOUS period, and the correction is
      # issued now. Decision D08: the correction belongs to the original's
      # period, so it is the previous period's invoice that changes.
      previous = ~U[2026-07-15 09:30:00.000000Z]
      assert {:ok, original, :inserted} = record(ctx, "old", 10, occurred_at: previous)

      refute DateTime.compare(original.period_start, ctx.period) == :eq

      assert {:ok, correction, :inserted} = AuroraMeter.correct(ctx.tenant, "old", 4, id: "fix")

      assert correction.feature == original.feature
      assert correction.period_start == original.period_start
      assert correction.period_source == original.period_source
      assert correction.occurred_at == original.occurred_at
      assert correction.attribution == original.attribution
      assert correction.plan_id == original.plan_id
      assert correction.plan_version == original.plan_version

      # The previous period's total moved and the current one did not exist at
      # all, which is the whole of "it changes the right invoice".
      assert Events.total(ctx.tenant, :ai_generations, original.period_start) == 6
      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 0

      assert [%{period_start: period, quantity: 6, events: 2}] = totals(ctx.tenant)
      assert period == original.period_start
    end

    test "a correction inherits the original's dimensions", ctx do
      dimensions = %{"model" => "sonnet", "region" => "syd"}
      assert {:ok, _event, :inserted} = record(ctx, "base", 10, dimensions: dimensions)
      assert {:ok, correction, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 2, id: "fix")

      assert correction.dimensions == dimensions
    end

    test "a correction carries its own metadata, not the original's", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10, metadata: %{"a" => "original"})

      assert {:ok, correction, :inserted} =
               AuroraMeter.correct(ctx.tenant, "base", 2,
                 id: "fix",
                 metadata: %{"ticket" => "SUP-42"}
               )

      assert correction.metadata == %{"ticket" => "SUP-42"}
    end

    test "the original row is never updated", ctx do
      assert {:ok, original, :inserted} = record(ctx, "base", 10)
      assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 4, id: "fix")

      assert {:ok, reread} = Events.get(ctx.tenant, "base")
      assert reread.quantity == 10
      assert reread.recorded_at == original.recorded_at
      assert reread.seq == original.seq
      assert reread.kind == :usage
    end
  end

  # -- the outbox seam ------------------------------------------------------

  describe "eligibility" do
    test "a correction of an events-source feature's event is staged as eligible", ctx do
      TestConfig.with_config(
        [
          {:aurora_meter, :events_outbox, RecordingOutbox},
          {:aurora_meter, :feature_sources, %{ai_generations: :events}}
        ],
        fn ->
          assert {:ok, _event, :inserted} = record(ctx, "base", 10)
          assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")

          assert [_usage, %{event: correction, eligibility: :eligible}] = RecordingOutbox.items()
          assert correction.kind == :correction
          assert correction.event_id == "fix"
        end
      )
    end

    test "a correction of a buffered feature's event is stored and marked ineligible", ctx do
      TestConfig.with_config(
        [
          {:aurora_meter, :events_outbox, RecordingOutbox},
          {:aurora_meter, :feature_sources, %{ai_generations: :buffered}}
        ],
        fn ->
          assert {:ok, _event, :inserted} = record(ctx, "base", 10)
          assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")

          items = RecordingOutbox.items()
          assert %{eligibility: {:ineligible, :feature_buffered}} = List.last(items)

          # Stored, not dropped: the fact is in the ledger even though core can
          # already tell it cannot be delivered.
          assert length(rows(ctx.tenant)) == 2
          assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 7
        end
      )
    end

    test "a correction of an unattributed original is marked ineligible original_ineligible",
         ctx do
      TestConfig.with_config(
        [
          {:aurora_meter, :events_outbox, RecordingOutbox},
          {:aurora_meter, :period_source, PeriodSources.FutureWindow}
        ],
        fn ->
          assert {:ok, original, :inserted} = record(ctx, "base", 10)
          assert original.attribution == :unresolved

          assert {:ok, correction, :inserted} =
                   AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")

          assert correction.attribution == :unresolved

          assert %{eligibility: {:ineligible, :original_ineligible}} =
                   List.last(RecordingOutbox.items())

          assert length(rows(ctx.tenant)) == 2
        end
      )
    end

    test "a duplicate correction stages no second intent", ctx do
      TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        assert {:ok, _event, :inserted} = record(ctx, "base", 10)
        assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")
        assert {:ok, _c, :duplicate} = AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")

        assert length(RecordingOutbox.items()) == 2
      end)
    end

    test "an outbox that refuses rolls the correction back", ctx do
      TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        assert {:ok, _event, :inserted} = record(ctx, "base", 10)
        RecordingOutbox.fail!(:staging_unavailable)

        assert AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix") ==
                 {:error, {:unavailable, {:outbox, :staging_unavailable}}}

        assert length(rows(ctx.tenant)) == 1
        assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 10
      end)
    end
  end

  # -- host transactions ----------------------------------------------------

  describe "inside a host transaction" do
    test "I09 a refusal does not roll back the host's transaction", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 10, id: "fix-all")

      receipt = Ecto.UUID.generate()

      assert {:ok, :refused} =
               TestRepo.transaction(fn ->
                 TestRepo.insert_all(AuroraMeter.Schema.FlushReceipt, [
                   %{id: receipt, inserted_at: AuroraMeter.Clock.now()}
                 ])

                 assert AuroraMeter.correct(ctx.tenant, "base", 1, id: "too-much") ==
                          {:error, {:invalid, [quantity: :exceeds_original]}}

                 :refused
               end)

      # The host's own write survived the refusal, which is the whole reason a
      # refusal returns rather than calling repo.rollback/1.
      assert TestRepo.get(AuroraMeter.Schema.FlushReceipt, receipt)
    end

    test "a correction inside a host transaction is conditional and defers its effects", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)

      assert {:ok, correction} =
               TestRepo.transaction(fn ->
                 assert {:ok, event, :inserted} =
                          AuroraMeter.correct(ctx.tenant, "base", 4, id: "fix")

                 event
               end)

      assert correction.durability == :conditional

      # The totals delta is inside the host's transaction and committed with it.
      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 6
    end
  end

  # -- the in-memory projection ---------------------------------------------

  describe "the in-memory projection" do
    test "I09 the ETS projection subtracts and never shows a negative value", ctx do
      TestConfig.with_config(
        [{:aurora_meter, :feature_sources, %{ai_generations: :events}}],
        fn ->
          assert {:ok, _event, :inserted} = record(ctx, "base", 10, feature: :ai_generations)

          # Warm the key so the projection has something to move.
          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 10

          assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 4, id: "fix")
          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 6
        end
      )
    end

    test "I09 a correction whose magnitude exceeds this node's view re-seats it from the durable total",
         ctx do
      TestConfig.with_config(
        [{:aurora_meter, :feature_sources, %{ai_generations: :events}}],
        fn ->
          assert {:ok, _event, :inserted} = record(ctx, "base", 10, feature: :ai_generations)
          key = {ctx.tenant, :ai_generations, ctx.period}

          # The shape of a node that seeded its ETS row AFTER the original was
          # recorded on another node: the row exists and is too low. Without the
          # clamp, subtracting 4 from 1 shows -3 to every dashboard on this node.
          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 10
          Counter.rebase(key, 1, :gossip)
          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 1

          assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 4, id: "fix")

          # Re-seated from the durable total, which is 6: not merely non-negative
          # but right.
          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 6
          assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 6
        end
      )
    end

    test "a correction never marks the key dirty or pending flush", ctx do
      TestConfig.with_config(
        [{:aurora_meter, :feature_sources, %{ai_generations: :events}}],
        fn ->
          assert {:ok, _event, :inserted} = record(ctx, "base", 10, feature: :ai_generations)
          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 10
          assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 4, id: "fix")

          key = {ctx.tenant, :ai_generations, ctx.period}
          refute key in Counter.dirty_keys()
          assert [{^key, _value, 0, _gossip, _remote, _reserved}] = :ets.lookup(table(), key)
        end
      )
    end

    test "a correction of a past period does not touch the current period's counter", ctx do
      TestConfig.with_config(
        [{:aurora_meter, :feature_sources, %{ai_generations: :events}}],
        fn ->
          previous = ~U[2026-07-15 09:30:00.000000Z]

          assert {:ok, _event, :inserted} =
                   record(ctx, "old", 10, feature: :ai_generations, occurred_at: previous)

          assert {:ok, _now, :inserted} = record(ctx, "new", 5, feature: :ai_generations)

          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 5
          assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "old", 4, id: "fix")
          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 5
        end
      )
    end
  end

  defp table, do: Store.counters_table()

  # -- PubSub ---------------------------------------------------------------

  describe "PubSub" do
    test "a correction message carries kind: :correction and the positive magnitude", ctx do
      Phoenix.PubSub.subscribe(
        AuroraMeter.Config.pubsub(),
        AuroraMeter.Broadcaster.topic(ctx.tenant)
      )

      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      assert_receive {:aurora_meter, :event, %{event_id: "base", kind: :usage}}, 2_000

      assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 3, id: "fix")

      assert_receive {:aurora_meter, :event, message}, 2_000
      assert message.event_id == "fix"
      assert message.kind == :correction
      assert message.quantity == 3
      assert message.period_start == ctx.period
    end
  end

  # -- capability -----------------------------------------------------------

  describe "capability" do
    test "an adapter that does not declare :corrections refuses before it is called", ctx do
      TestConfig.with_config([{:aurora_meter, :storage, IncapableStorage}], fn ->
        assert AuroraMeter.correct(ctx.tenant, "base", 1, id: "fix") ==
                 {:error, {:unsupported, :corrections}}
      end)
    end
  end

  # -- the arithmetic a replay has to reproduce -----------------------------

  describe "replay arithmetic" do
    test "I09 recomputing every total from the event rows reproduces the projection exactly",
         ctx do
      # 100 events and 40 corrections across three keys, then the comparison
      # `AuroraMeter.Events.Replay` (03d, phase 3) makes: recompute each key's
      # total from the rows with L-03e-3's rule and assert it equals what the
      # live path projected. The replay itself is 03d's; its ARITHMETIC is this
      # unit's, and a disagreement here would make a replay rewrite every
      # corrected total wrongly.
      months = [
        ~U[2026-07-05 10:00:00.000000Z],
        ~U[2026-08-05 10:00:00.000000Z],
        ~U[2026-09-05 10:00:00.000000Z]
      ]

      for n <- 1..100 do
        at = Enum.at(months, rem(n, 3))
        assert {:ok, _event, :inserted} = record(ctx, "e-#{n}", rem(n, 7) + 3, occurred_at: at)
      end

      for n <- 1..40 do
        assert {:ok, _c, :inserted} =
                 AuroraMeter.correct(ctx.tenant, "e-#{n}", rem(n, 3) + 1, id: "c-#{n}")
      end

      recomputed =
        ctx.tenant
        |> rows()
        |> Enum.group_by(& &1.period_start)
        |> Map.new(fn {period, group} ->
          quantity =
            Enum.reduce(group, 0, fn row, acc ->
              if row.kind == "correction", do: acc - row.quantity, else: acc + row.quantity
            end)

          {period, %{quantity: quantity, events: length(group)}}
        end)

      projected =
        Map.new(totals(ctx.tenant), fn t ->
          {t.period_start, %{quantity: t.quantity, events: t.events}}
        end)

      assert map_size(projected) == 3
      assert projected == recomputed

      # And every projected quantity is what `Events.total/3` answers.
      for {period, %{quantity: quantity}} <- projected do
        assert Events.total(ctx.tenant, :ai_generations, period) == quantity
      end
    end
  end

  # -- the period the correction lands in, once more ------------------------

  describe "period attribution" do
    test "a correction issued in a later period still totals into the original's", ctx do
      previous = ~U[2026-06-02 00:00:00.000000Z]
      assert {:ok, original, :inserted} = record(ctx, "old", 8, occurred_at: previous)
      assert {:ok, _now, :inserted} = record(ctx, "new", 8)

      assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "old", 5, id: "fix")

      assert Events.total(ctx.tenant, :ai_generations, original.period_start) == 3
      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 8

      assert Period.containing(ctx.tenant, previous).start == original.period_start
    end
  end
end
