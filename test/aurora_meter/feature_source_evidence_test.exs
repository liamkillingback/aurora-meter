defmodule AuroraMeter.FeatureSourceEvidenceTest do
  @moduledoc """
  Build unit 03c's evidence generator: it measures the two tables 03c's build
  document asks for and writes them, rather than leaving them to be transcribed
  by hand from a log.

  It is a test rather than a script because the numbers have to be produced by
  the same code path the suite exercises, on the same database, under the same
  harness. It asserts every number it records, so a run that writes the files is
  a run that also proved them; `mix test` fails if the measurement disagrees with
  the contract, and the files are then not written.

  The measurements are **asserted on every run** and **written only when asked**:

      AURORA_EVIDENCE=1 mix test test/aurora_meter/feature_source_evidence_test.exs

  writes `docs/evidence/v1/phase-03/03c-flush-isolation.json` and
  `03c-quota-matrix.md`; a plain run asserts the same numbers and writes nothing.
  The split is deliberate. `mix check` is supposed to leave the working tree
  byte identical (`open-findings.md` X21 and X27 are two occasions when it did
  not), and a test that stamped a fresh `generated_at` into two committed files
  on every gate run would quietly break that. Asserting always and writing on
  request keeps the guard without the churn.

  `async: false`, like every test that drives the flusher.
  """
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test.Config, only: [with_config: 2]

  alias AuroraMeter.Events
  alias AuroraMeter.Flusher
  alias AuroraMeter.Period
  alias AuroraMeter.Storage
  alias AuroraMeter.Store

  @evidence "docs/evidence/v1/phase-03"

  @events_source [{:aurora_meter, :feature_sources, %{ai_generations: :events}}]

  setup do
    tenant = unique_tenant("evidence")
    {:ok, tenant: tenant, period: Period.current!(tenant).start, at: AuroraMeter.Clock.now()}
  end

  test "evidence: one thousand recorded events produce an empty flush batch and no counter row",
       ctx do
    {:ok, _drained} = Flusher.flush()

    measured =
      with_config(@events_source, fn ->
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

        for batch <- 0..1 do
          elements =
            for n <- 1..500 do
              %{
                tenant: ctx.tenant,
                feature: :ai_generations,
                quantity: 1,
                id: "evidence-#{batch}-#{n}",
                occurred_at: ctx.at
              }
            end

          assert {:ok, results} = AuroraMeter.record_batch(elements)
          assert length(results) == 500
        end

        batch = Store.snapshot_flush_batch()
        {:ok, flushed} = Flusher.flush()

        %{
          records: 1000,
          feature: "ai_generations",
          ets_value_before_flush: AuroraMeter.usage(ctx.tenant, :ai_generations),
          flush_batch: describe_batch(batch, ctx.tenant),
          flush_keys_persisted: flushed,
          load_counter_after_flush: Storage.load_counter(ctx.tenant, :ai_generations, ctx.period),
          events_total_after_flush: Events.total(ctx.tenant, :ai_generations, ctx.period),
          event_rows: Events.count(ctx.tenant, :ai_generations, ctx.period)
        }
      end)

    assert measured.ets_value_before_flush == 1000
    assert measured.flush_batch.counters_for_tenant == []
    assert measured.flush_batch.history_for_tenant == []
    assert measured.load_counter_after_flush == nil
    assert measured.events_total_after_flush == 1000
    assert measured.event_rows == %{quantity: 1000, events: 1000}

    write_json("03c-flush-isolation.json", %{
      unit: "03c",
      generated_at: DateTime.to_iso8601(DateTime.utc_now()),
      what:
        "After 1000 AuroraMeter.record/4 quantities for an :events-source feature: the " <>
          "flush batch, the counter row a Pro reporter would read, and the durable total.",
      expected: %{
        flush_batch_entries_for_tenant: 0,
        load_counter: nil,
        events_total: 1000
      },
      observed: measured
    })
  end

  test "evidence: the eight with_quota outcomes, two sources by four endings", ctx do
    {:ok, _drained} = Flusher.flush()

    buffered = for outcome <- outcomes(), do: measure(:buffered, outcome, ctx)
    events = for outcome <- outcomes(), do: measure(:events, outcome, ctx)

    rows = buffered ++ events

    # The contract, asserted here and written out below. Every cell releases its
    # reservation one way or another, so `reserved` is zero everywhere.
    for row <- rows do
      assert row.reserved_after == 0
      assert row.durable_total == expected_total(row)
    end

    for row <- buffered do
      case row.outcome do
        :normal ->
          assert row.value_after == 5
          # Read before the snapshot: the commit put 5 into `pending_flush`, and
          # the snapshot below is what takes it.
          assert row.pending_flush_after == 5
          assert row.flush_batch_entries == 1
          assert row.counter_row_after_flush == 5

        _failed ->
          assert row.value_after == 0
          assert row.flush_batch_entries == 0
          assert row.counter_row_after_flush == nil
      end
    end

    for row <- events do
      # L-03c-2: the in-memory value for an events-source key settles on the
      # durable total. On the normal ending that is the recorded 5 (+5 estimate,
      # +5 projection, -5 release); on every failure it is zero.
      assert row.value_after == row.durable_total
      assert row.pending_flush_after == 0
      assert row.flush_batch_entries == 0
      assert row.counter_row_after_flush == nil
    end

    write_file("03c-quota-matrix.md", quota_matrix(rows))
  end

  # -- measurement -----------------------------------------------------------

  defp outcomes, do: [:normal, :raise, :throw, :exit]

  # One tenant per cell, so the eight rows cannot contaminate each other and
  # each number is the whole of that cell's effect.
  defp measure(source, outcome, ctx) do
    tenant = unique_tenant("quota_#{source}_#{outcome}")
    period = Period.current!(tenant).start
    key = {tenant, :ai_generations, period}
    overrides = if source == :events, do: source_override(), else: []

    {:ok, _drained} = Flusher.flush()

    with_config(overrides, fn ->
      # Warm the key so a projection inside the callback is applied rather than
      # skipped as cold.
      assert AuroraMeter.usage(tenant, :ai_generations) == 0

      run_quota(tenant, outcome, ctx.at)

      [{^key, value, pending_flush, _gossip, _remote, reserved}] =
        :ets.lookup(Store.counters_table(), key)

      batch = Store.snapshot_flush_batch()
      entries = describe_batch(batch, tenant)
      {:ok, _flushed} = Flusher.flush()

      %{
        source: source,
        outcome: outcome,
        value_after: value,
        pending_flush_after: pending_flush,
        reserved_after: reserved,
        flush_batch_entries: length(entries.counters_for_tenant),
        counter_row_after_flush: Storage.load_counter(tenant, :ai_generations, period),
        durable_total: Events.total(tenant, :ai_generations, period)
      }
    end)
  end

  defp source_override, do: [{:aurora_meter, :feature_sources, %{ai_generations: :events}}]

  # Every cell reserves 5 and, on the normal ending, records 5. The recorded
  # quantity is deliberately equal to the estimate so the two sources' rows are
  # comparable at a glance: the difference between them is then entirely the
  # settle rule and not the arithmetic.
  defp run_quota(tenant, :normal, at) do
    {:ok, :done} =
      AuroraMeter.with_quota(tenant, :ai_generations, 5, fn ->
        if AuroraMeter.Config.feature_source(:ai_generations) == :events do
          {:ok, _event, :inserted} =
            AuroraMeter.record(tenant, :ai_generations, 5,
              id: "quota-#{tenant}",
              occurred_at: at
            )
        end

        :done
      end)
  end

  defp run_quota(tenant, :raise, _at) do
    assert_raise RuntimeError, fn ->
      AuroraMeter.with_quota(tenant, :ai_generations, 5, fn -> raise "boom" end)
    end
  end

  defp run_quota(tenant, :throw, _at) do
    catch_throw(AuroraMeter.with_quota(tenant, :ai_generations, 5, fn -> throw(:nope) end))
  end

  defp run_quota(tenant, :exit, _at) do
    catch_exit(AuroraMeter.with_quota(tenant, :ai_generations, 5, fn -> exit(:timeout) end))
  end

  defp expected_total(%{source: :events, outcome: :normal}), do: 5
  defp expected_total(_row), do: 0

  defp describe_batch(nil, _tenant),
    do: %{present: false, counters_for_tenant: [], history_for_tenant: []}

  defp describe_batch(batch, tenant) do
    %{
      present: true,
      counters_for_tenant: for(c <- batch.counters, c.tenant_key == tenant, do: summarise(c)),
      history_for_tenant: for(h <- batch.history, h.tenant_key == tenant, do: summarise(h))
    }
  end

  defp summarise(%{feature: feature, delta: delta}),
    do: %{feature: to_string(feature), delta: delta}

  # -- rendering -------------------------------------------------------------

  defp quota_matrix(rows) do
    """
    # 03c: the `with_quota/4` outcome matrix

    Measured by `AuroraMeter.FeatureSourceEvidenceTest`, which asserts every
    number below before writing this file. Generated #{DateTime.to_iso8601(DateTime.utc_now())}.

    Each cell is a fresh tenant. The callback reserves **5**, and on the normal
    ending an `:events`-source callback also records **5**, so the only
    difference between the two halves of the table is the settle rule rather than
    the arithmetic.

    `value`, `pending_flush` and `reserved` are the ETS row read immediately
    after the call and **before** the flush-batch snapshot, which is the reading
    that shows what the call itself left behind: the snapshot is what takes
    `pending_flush` away. `flush entries` counts what that snapshot then held for
    that tenant.
    `counter row` is `AuroraMeter.Storage.load_counter/3` after a flush, which is
    the exact read `AuroraMeter.Pro.UsageReporter.report_one/5` makes and
    therefore the only number that can become a charge. `durable total` is
    `AuroraMeter.Events.total/3`.

    | source | callback ends | value | pending_flush | reserved | flush entries | counter row | durable total |
    |---|---|---|---|---|---|---|---|
    #{Enum.map_join(rows, "\n", &row_line/1)}

    ## What the table says

    **The buffered half is unchanged**, and is here as the control: a normal
    return commits the reservation, so `value` stays at 5, the delta reaches the
    flush batch and `aurora_meter_counters` holds 5 afterwards. A raise, a throw
    and an exit each release it, and nothing is persisted.

    **The events half never writes a counter row at all.** On every ending,
    including the successful one, the reservation is released: `pending_flush` is
    never written, the flush batch is empty for that tenant and `load_counter/3`
    is `nil`. `value` does not simply return to zero on the successful row, and
    that is the point rather than an exception: the estimate came back
    (`+5`, `-5`) and the projection of the recorded event stayed (`+5`), so the
    in-memory value settles on the durable total. On the three failing rows
    nothing was recorded, so both are zero.

    That last line is the whole of I08 on this path. A reservation over an
    events-source feature is admission control; the charge is the event.
    """
  end

  defp row_line(row) do
    "| `#{row.source}` | #{row.outcome} | #{row.value_after} | #{row.pending_flush_after} | " <>
      "#{row.reserved_after} | #{row.flush_batch_entries} | " <>
      "#{inspect(row.counter_row_after_flush)} | #{row.durable_total} |"
  end

  defp write_json(name, data), do: write_file(name, Jason.encode!(data, pretty: true) <> "\n")

  defp write_file(name, contents) do
    if System.get_env("AURORA_EVIDENCE") == "1" do
      File.mkdir_p!(@evidence)
      File.write!(Path.join(@evidence, name), contents)
    end

    :ok
  end
end
