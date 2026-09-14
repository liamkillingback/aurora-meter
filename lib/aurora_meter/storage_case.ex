defmodule AuroraMeter.StorageCase do
  @moduledoc """
  The conformance suite every `AuroraMeter.Storage` adapter should pass.

  Aurora Meter ships one adapter, `AuroraMeter.Storage.Ecto`. Writing another
  one is supported, and this is how you find out whether yours is correct
  before it is asked to hold money. `use` it inside an ExUnit case that already
  knows how to reach your storage:

      defmodule MyApp.RiakStorageTest do
        use ExUnit.Case, async: false
        use AuroraMeter.StorageCase, adapter: MyApp.RiakStorage
      end

  It installs your adapter as `config :aurora_meter, :storage` for the
  duration of each test and restores whatever was there before, then drives it
  through `AuroraMeter.Storage`'s own dispatchers rather than calling your
  module directly: what a host observes is what is asserted.

  ## Options

    * `:adapter` (**required**) the module under test.
    * `:checkout` `{module, function}` called with no arguments in `setup`,
      for an adapter that needs a connection checked out first. The Ecto
      adapter under the SQL sandbox does; an in-memory one will not.
    * `:tenant_prefix` a string the generated tenant keys start with, so your
      own cleanup can find them. Default `"storage_case"`.

  ## What it asserts

  An adapter that declares `:durable_events` must record, deduplicate by
  identity, refuse a changed payload under an identity it already holds, keep
  its totals arithmetic exact, and not project a duplicate a second time. An
  adapter that declares nothing must answer `{:error, {:unsupported, _}}` from
  every durable dispatcher. **Both pass this suite**: declining the work is a
  supported answer, and the difference between declining it and faking it is
  the difference between a caller that can handle the situation and one that
  cannot.

  Each assertion lives in a public function of this module and the generated
  `test` blocks are one line each, so a failure names the function you can read
  rather than a line inside a macro expansion.

  It does not assert anything about counters or history: those callbacks
  predate this suite and the existing adapter tests cover them. It does assert
  `c:AuroraMeter.Storage.list_subscriptions/2`, which does not predate it: a
  keyset page that repeats or skips a row is a subscription billed twice or not
  at all, and that is not something an adapter author should have to discover
  in production.
  """

  import ExUnit.Assertions

  alias AuroraMeter.Events.Canonical
  alias AuroraMeter.Storage

  @capabilities [:durable_events, :corrections, :projection_generations, :event_streaming]

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @storage_case_adapter Keyword.get(opts, :adapter) ||
                              raise(ArgumentError, "use AuroraMeter.StorageCase, adapter: Mod")
      @storage_case_checkout Keyword.get(opts, :checkout)
      @storage_case_prefix Keyword.get(opts, :tenant_prefix, "storage_case")

      setup do
        AuroraMeter.StorageCase.install!(
          @storage_case_adapter,
          @storage_case_checkout,
          @storage_case_prefix
        )
      end

      describe "AuroraMeter.StorageCase: capabilities" do
        test "capabilities/0 returns a list drawn from the known vocabulary" do
          AuroraMeter.StorageCase.assert_capability_vocabulary!()
        end

        test "supports?/1 agrees with capabilities/0" do
          AuroraMeter.StorageCase.assert_supports_agrees!()
        end

        test "an undeclared capability is refused by the dispatcher, not by the adapter", ctx do
          AuroraMeter.StorageCase.assert_undeclared_refused!(ctx)
        end
      end

      describe "AuroraMeter.StorageCase: durable events" do
        @describetag :storage_case

        test "an identity is recorded once and a retry of it is a duplicate", ctx do
          AuroraMeter.StorageCase.assert_identity!(ctx)
        end

        test "a changed payload under an identity already held is a conflict, and writes nothing",
             ctx do
          AuroraMeter.StorageCase.assert_conflict!(ctx)
        end

        test "totals add the inserted rows and never a duplicate", ctx do
          AuroraMeter.StorageCase.assert_totals!(ctx)
        end

        test "results come back in the caller's input order", ctx do
          AuroraMeter.StorageCase.assert_input_order!(ctx)
        end

        test "load_event/2 round trips and is not found for an unknown id", ctx do
          AuroraMeter.StorageCase.assert_load_event!(ctx)
        end

        test "load_event_total/3 is zero for a period nothing was recorded in", ctx do
          AuroraMeter.StorageCase.assert_empty_total!(ctx)
        end

        test "an identity is per tenant, not global", ctx do
          AuroraMeter.StorageCase.assert_identity_is_per_tenant!(ctx)
        end
      end

      describe "AuroraMeter.StorageCase: corrections" do
        @describetag :storage_case

        test "a correction reduces the original's total and is its own row", ctx do
          AuroraMeter.StorageCase.assert_correction!(ctx)
        end

        test "a repeated correction id is a duplicate, with no second delta", ctx do
          AuroraMeter.StorageCase.assert_correction_duplicate!(ctx)
        end

        test "a correction id reused with a different magnitude is a conflict", ctx do
          AuroraMeter.StorageCase.assert_correction_conflict!(ctx)
        end

        test "cumulative corrections cannot exceed the original", ctx do
          AuroraMeter.StorageCase.assert_correction_bound!(ctx)
        end

        test "a correction inherits the original's feature, period and occurrence", ctx do
          AuroraMeter.StorageCase.assert_correction_inheritance!(ctx)
        end

        test "a correction of a missing original, and of a correction, are both refused", ctx do
          AuroraMeter.StorageCase.assert_correction_refusals!(ctx)
        end
      end

      describe "AuroraMeter.StorageCase: streaming" do
        @describetag :storage_case

        test "stream_events/2 is ordered by seq and bounded by limit", ctx do
          AuroraMeter.StorageCase.assert_streaming!(ctx)
        end
      end

      describe "AuroraMeter.StorageCase: subscriptions" do
        @describetag :storage_case

        test "list_subscriptions/2 pages by keyset without repeating or skipping a row",
             ctx do
          AuroraMeter.StorageCase.assert_subscription_paging!(ctx)
        end

        test "list_subscriptions/2 honours status_in and ends its cursor", ctx do
          AuroraMeter.StorageCase.assert_subscription_filter!(ctx)
        end
      end

      describe "AuroraMeter.StorageCase: projection generations" do
        @describetag :storage_case

        test "write_projection_totals/2 then activate_projection/1 changes what reads see", ctx do
          AuroraMeter.StorageCase.assert_generations!(ctx)
        end

        test "write_projection_totals/2 adds to a generation rather than replacing it", ctx do
          AuroraMeter.StorageCase.assert_generation_adds!(ctx)
        end

        test "begin_projection_generation/0 announces a generation, a watermark and a seed",
             ctx do
          AuroraMeter.StorageCase.assert_announcement!(ctx)
        end

        test "drain_projection_seed/2 takes the seed back out in bounded slices", ctx do
          AuroraMeter.StorageCase.assert_seed_drain!(ctx)
        end
      end
    end
  end

  @doc """
  Installs the adapter for one test and returns the context the assertions take.

  Restores the previous `:storage` configuration in `on_exit`, including
  deleting the key when it was absent.
  """
  @spec install!(module(), {module(), atom()} | nil, String.t()) :: map()
  def install!(adapter, checkout, prefix) do
    case checkout do
      {module, function} -> apply(module, function, [])
      nil -> :ok
    end

    previous = Application.fetch_env(:aurora_meter, :storage)
    Application.put_env(:aurora_meter, :storage, adapter)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aurora_meter, :storage, value)
        :error -> Application.delete_env(:aurora_meter, :storage)
      end
    end)

    # Fixed instants, not `Clock.now/0` and certainly not `DateTime.utc_now/0`:
    # a conformance suite that moves with the wall clock cannot be compared
    # between two runs, and every clock read in this package goes through
    # `AuroraMeter.Clock` (`architecture-map.md` section 3).
    %{
      storage_tenant: "#{prefix}_#{System.unique_integer([:positive])}",
      storage_at: ~U[2026-01-15 12:00:00.000000Z],
      storage_period: ~U[2026-01-01 00:00:00Z]
    }
  end

  @doc "The capability vocabulary an adapter may draw from."
  @spec capabilities() :: [AuroraMeter.Storage.capability()]
  def capabilities, do: @capabilities

  @doc false
  @spec assert_capability_vocabulary!() :: true
  def assert_capability_vocabulary! do
    declared = Storage.capabilities()

    assert is_list(declared)
    assert declared -- @capabilities == [], "unknown capabilities: #{inspect(declared)}"
    assert declared == Enum.uniq(declared)
  end

  @doc false
  @spec assert_supports_agrees!() :: :ok
  def assert_supports_agrees! do
    Enum.each(@capabilities, fn capability ->
      assert Storage.supports?(capability) == capability in Storage.capabilities()
    end)
  end

  @doc false
  @spec assert_generation_adds!(map()) :: :ok
  def assert_generation_adds!(ctx) do
    durable(:projection_generations, fn ->
      row = fn quantity, events ->
        %{
          tenant_key: ctx.storage_tenant,
          feature: "storage_case",
          period_start: ctx.storage_period,
          quantity: quantity,
          events: events
        }
      end

      assert :ok = Storage.write_projection_totals(2, [row.(10, 2)])
      assert :ok = Storage.write_projection_totals(2, [row.(5, 1)])

      # Adds, because a record that commits while a generation is being built
      # writes its own delta there too and a replay batch must not erase it.
      assert generation_total(ctx, 2) == %{quantity: 15, events: 3}

      # And a NEGATIVE delta is accepted onto a row that stays positive. A
      # replay reads events in `seq` order, so a batch can hold only
      # corrections for a key; an adapter that writes this as one
      # `INSERT ... ON CONFLICT DO UPDATE` is refused by its own
      # `quantity >= 0` check, on the tuple the insert proposes rather than the
      # row the update would leave (`open-findings.md` X124).
      assert :ok = Storage.write_projection_totals(2, [row.(-4, 1)])
      assert generation_total(ctx, 2) == %{quantity: 11, events: 4}
    end)
  end

  @doc false
  @spec assert_announcement!(map()) :: :ok
  def assert_announcement!(ctx) do
    durable(:projection_generations, fn ->
      active = active_generation()

      assert {:ok, [{_event, :inserted}]} =
               Storage.record_events([entry(ctx, "announce", 6)], [])

      try do
        assert {:ok, announced} = Storage.begin_projection_generation()

        assert announced.generation == active + 1
        assert announced.active_generation == active
        assert announced.watermark >= 1
        refute announced.resumed

        # The building generation starts as a copy of the active one, which is
        # what keeps a concurrent correction's negative delta off the
        # `quantity >= 0` check while the scan has not reached its key.
        assert generation_total(ctx, announced.generation) == %{quantity: 6, events: 1}
        assert generation_total(ctx, announced.seed_generation) == %{quantity: 6, events: 1}

        assert {:ok, state} = Storage.projection_state()
        assert state.active_generation == active
        assert state.building_generation == announced.generation
        assert state.seed_generation == announced.seed_generation
        assert state.watermark == announced.watermark

        # Idempotent: a second call resumes the first rather than announcing a
        # third generation nothing would ever write to.
        assert {:ok, again} = Storage.begin_projection_generation()
        assert again.generation == announced.generation
        assert again.resumed
      after
        restore_projection!(active)
      end

      # The restore is asserted, not assumed (open-findings.md X97).
      assert active_generation() == active
    end)
  end

  @doc false
  @spec assert_seed_drain!(map()) :: :ok
  def assert_seed_drain!(ctx) do
    durable(:projection_generations, fn ->
      active = active_generation()

      assert {:ok, [{_event, :inserted}]} = Storage.record_events([entry(ctx, "drain", 8)], [])

      try do
        assert {:ok, announced} = Storage.begin_projection_generation()
        building = announced.generation
        seed = announced.seed_generation

        # The scan's contribution, on top of the seed.
        assert :ok =
                 Storage.write_projection_totals(building, [
                   %{
                     tenant_key: ctx.storage_tenant,
                     feature: "storage_case",
                     period_start: ctx.storage_period,
                     quantity: 8,
                     events: 1
                   }
                 ])

        assert generation_total(ctx, building) == %{quantity: 16, events: 2}

        # Draining subtracts the seed and deletes it, so the generation holds
        # the scan plus whatever the live path wrote and nothing else. The seed
        # row's own existence is the cursor: draining until it returns 0 is the
        # whole of the bookkeeping.
        assert {:ok, drained} = Storage.drain_projection_seed(seed, 1000)
        assert drained >= 1
        assert {:ok, 0} = Storage.drain_projection_seed(seed, 1000)

        assert generation_total(ctx, building) == %{quantity: 8, events: 1}
        assert generation_total(ctx, seed) == %{quantity: 0, events: 0}
      after
        restore_projection!(active)
      end

      assert active_generation() == active
    end)
  end

  @doc false
  @spec assert_undeclared_refused!(map()) :: :ok
  def assert_undeclared_refused!(ctx) do
    unless Storage.supports?(:durable_events) do
      assert Storage.record_events([], []) == {:error, {:unsupported, :durable_events}}

      assert Storage.load_event(ctx.storage_tenant, "x") ==
               {:error, {:unsupported, :durable_events}}

      assert Storage.load_event_total(ctx.storage_tenant, :f, ctx.storage_period) ==
               {:error, {:unsupported, :durable_events}}
    end

    unless Storage.supports?(:corrections) do
      assert Storage.record_correction(correction(ctx, "x", "y", 1), []) ==
               {:error, {:unsupported, :corrections}}
    end

    unless Storage.supports?(:event_streaming) do
      assert Storage.stream_events(0, []) == {:error, {:unsupported, :event_streaming}}
    end

    unless Storage.supports?(:projection_generations) do
      assert Storage.write_projection_totals(0, []) ==
               {:error, {:unsupported, :projection_generations}}

      assert Storage.activate_projection(0) == {:error, {:unsupported, :projection_generations}}
    end

    :ok
  end

  @doc false
  @spec assert_identity!(map()) :: :ok
  def assert_identity!(ctx) do
    durable(fn ->
      entry = entry(ctx, "identity", 3)

      assert {:ok, [{first, :inserted}]} = Storage.record_events([entry], [])
      assert first.event_id == "identity"
      assert first.quantity == 3

      assert {:ok, [{second, :duplicate}]} = Storage.record_events([entry], [])
      assert second.id == first.id
    end)
  end

  @doc false
  @spec assert_conflict!(map()) :: :ok
  def assert_conflict!(ctx) do
    durable(fn ->
      assert {:ok, [{_event, :inserted}]} = Storage.record_events([entry(ctx, "conflict", 1)], [])

      assert {:error, {:conflict, 0, existing}} =
               Storage.record_events([entry(ctx, "conflict", 2)], [])

      assert existing.quantity == 1
      assert total(ctx) == %{quantity: 1, events: 1}
    end)
  end

  @doc false
  @spec assert_totals!(map()) :: :ok
  def assert_totals!(ctx) do
    durable(fn ->
      entries = for n <- 1..4, do: entry(ctx, "total-#{n}", n)

      assert {:ok, results} = Storage.record_events(entries, [])
      assert length(results) == 4
      assert total(ctx) == %{quantity: 10, events: 4}

      # A duplicate contributes nothing a second time, which is the whole of
      # "no second projection effect".
      assert {:ok, _again} = Storage.record_events(entries, [])
      assert total(ctx) == %{quantity: 10, events: 4}
    end)
  end

  @doc false
  @spec assert_input_order!(map()) :: :ok
  def assert_input_order!(ctx) do
    durable(fn ->
      ids = ["z", "a", "m"]
      entries = Enum.map(ids, &entry(ctx, &1, 1))

      assert {:ok, results} = Storage.record_events(entries, [])
      assert Enum.map(results, fn {event, _outcome} -> event.event_id end) == ids
    end)
  end

  @doc false
  @spec assert_load_event!(map()) :: :ok
  def assert_load_event!(ctx) do
    durable(fn ->
      assert {:ok, [{written, :inserted}]} =
               Storage.record_events([entry(ctx, "readback", 7)], [])

      assert {:ok, read} = Storage.load_event(ctx.storage_tenant, "readback")
      assert read.id == written.id
      assert read.quantity == 7
      assert read.occurred_at == written.occurred_at
      assert read.period_start == written.period_start
      assert read.seq == written.seq

      assert Storage.load_event(ctx.storage_tenant, "nope") == {:error, :not_found}
    end)
  end

  @doc false
  @spec assert_empty_total!(map()) :: :ok
  def assert_empty_total!(ctx) do
    durable(fn ->
      assert {:ok, %{quantity: 0, events: 0}} =
               Storage.load_event_total(
                 ctx.storage_tenant,
                 :storage_case,
                 ~U[2019-01-01 00:00:00Z]
               )
    end)
  end

  @doc false
  @spec assert_identity_is_per_tenant!(map()) :: :ok
  def assert_identity_is_per_tenant!(ctx) do
    durable(fn ->
      other = %{ctx | storage_tenant: ctx.storage_tenant <> "_other"}

      assert {:ok, [{_a, :inserted}]} = Storage.record_events([entry(ctx, "shared", 1)], [])
      assert {:ok, [{_b, :inserted}]} = Storage.record_events([entry(other, "shared", 1)], [])
    end)
  end

  @doc false
  @spec assert_correction!(map()) :: :ok
  def assert_correction!(ctx) do
    corrections(fn ->
      assert {:ok, [{_event, :inserted}]} = Storage.record_events([entry(ctx, "c-base", 10)], [])

      assert {:ok, [{correction, :inserted}]} =
               Storage.record_correction(correction(ctx, "c-fix", "c-base", 3), [])

      assert correction.kind == :correction
      assert correction.quantity == 3
      assert correction.original_event_id == "c-base"

      # The quantity is the usage less the correction; the count is the number
      # of rows, of both kinds.
      assert total(ctx) == %{quantity: 7, events: 2}
    end)
  end

  @doc false
  @spec assert_correction_duplicate!(map()) :: :ok
  def assert_correction_duplicate!(ctx) do
    corrections(fn ->
      assert {:ok, [{_event, :inserted}]} = Storage.record_events([entry(ctx, "d-base", 10)], [])
      request = correction(ctx, "d-fix", "d-base", 10)

      assert {:ok, [{first, :inserted}]} = Storage.record_correction(request, [])

      # The original is by now fully corrected, and the retry is still a
      # duplicate rather than `exceeds_original`: the duplicate check precedes
      # the bound check, and this is the assertion that pins it.
      assert {:ok, [{second, :duplicate}]} = Storage.record_correction(request, [])

      assert second.id == first.id
      assert total(ctx) == %{quantity: 0, events: 2}
    end)
  end

  @doc false
  @spec assert_correction_conflict!(map()) :: :ok
  def assert_correction_conflict!(ctx) do
    corrections(fn ->
      assert {:ok, [{_event, :inserted}]} = Storage.record_events([entry(ctx, "x-base", 10)], [])

      assert {:ok, [{_c, :inserted}]} =
               Storage.record_correction(correction(ctx, "x-fix", "x-base", 3), [])

      assert {:error, {:conflict, 0, existing}} =
               Storage.record_correction(correction(ctx, "x-fix", "x-base", 4), [])

      assert existing.quantity == 3
      assert total(ctx) == %{quantity: 7, events: 2}
    end)
  end

  @doc false
  @spec assert_correction_bound!(map()) :: :ok
  def assert_correction_bound!(ctx) do
    corrections(fn ->
      assert {:ok, [{_event, :inserted}]} = Storage.record_events([entry(ctx, "b-base", 10)], [])

      assert {:ok, [{_c, :inserted}]} =
               Storage.record_correction(correction(ctx, "b-1", "b-base", 6), [])

      assert Storage.record_correction(correction(ctx, "b-2", "b-base", 5), []) ==
               {:error, {:invalid, [quantity: :exceeds_original]}}

      assert total(ctx) == %{quantity: 4, events: 2}
    end)
  end

  @doc false
  @spec assert_correction_inheritance!(map()) :: :ok
  def assert_correction_inheritance!(ctx) do
    corrections(fn ->
      assert {:ok, [{original, :inserted}]} =
               Storage.record_events([entry(ctx, "i-base", 4)], [])

      assert {:ok, [{correction, :inserted}]} =
               Storage.record_correction(correction(ctx, "i-fix", "i-base", 1), [])

      assert correction.feature == original.feature
      assert correction.period_start == original.period_start
      assert correction.period_source == original.period_source
      assert correction.occurred_at == original.occurred_at
    end)
  end

  @doc false
  @spec assert_correction_refusals!(map()) :: :ok
  def assert_correction_refusals!(ctx) do
    corrections(fn ->
      assert Storage.record_correction(correction(ctx, "r-fix", "r-nothing", 1), []) ==
               {:error, {:not_found, :original}}

      assert {:ok, [{_event, :inserted}]} = Storage.record_events([entry(ctx, "r-base", 5)], [])

      assert {:ok, [{_c, :inserted}]} =
               Storage.record_correction(correction(ctx, "r-1", "r-base", 1), [])

      assert Storage.record_correction(correction(ctx, "r-2", "r-1", 1), []) ==
               {:error, {:invalid, [original: :is_correction]}}
    end)
  end

  @doc false
  @spec assert_streaming!(map()) :: :ok
  def assert_streaming!(ctx) do
    durable(:event_streaming, fn ->
      entries = for n <- 1..5, do: entry(ctx, "stream-#{n}", 1)
      assert {:ok, _results} = Storage.record_events(entries, [])

      assert {:ok, page} = Storage.stream_events(0, tenant: ctx.storage_tenant, limit: 2)
      assert length(page) == 2

      seqs = Enum.map(page, & &1.seq)
      assert seqs == Enum.sort(seqs)

      assert {:ok, next} =
               Storage.stream_events(List.last(seqs), tenant: ctx.storage_tenant, limit: 10)

      assert length(next) == 3
      assert Enum.all?(next, &(&1.seq > List.last(seqs)))
    end)
  end

  @doc false
  # Paged one row at a time, which is the setting that exposes the two ways a
  # keyset goes wrong: a cursor that is inclusive repeats its own last row for
  # ever, and a cursor built from anything but the sort key skips rows. Neither
  # shows up at a page size larger than the data.
  @spec assert_subscription_paging!(map()) :: :ok
  def assert_subscription_paging!(ctx) do
    keys = subscription_keys(ctx)
    for key <- Enum.shuffle(keys), do: put_subscription!(key, "active")

    one_at_a_time = drain_subscriptions(limit: 1)

    assert one_at_a_time == Enum.uniq(one_at_a_time),
           "list_subscriptions/2 returned a tenant_key twice while paging by one"

    assert one_at_a_time == Enum.sort(one_at_a_time),
           "list_subscriptions/2 is not in ascending tenant_key order"

    assert keys -- one_at_a_time == [],
           "paging by one skipped #{inspect(keys -- one_at_a_time)}"

    in_bulk = drain_subscriptions(limit: 500)

    assert Enum.sort(in_bulk) == Enum.sort(one_at_a_time),
           "the page size changed which rows came back"

    :ok
  end

  @doc false
  @spec assert_subscription_filter!(map()) :: :ok
  def assert_subscription_filter!(ctx) do
    [first, second, third] = keys = subscription_keys(ctx)
    put_subscription!(first, "active")
    put_subscription!(second, "canceled")
    put_subscription!(third, "active")

    active = drain_subscriptions(limit: 500, status_in: ["active"])

    assert first in active and third in active
    refute second in active, "status_in did not exclude a status it was not given"

    everything = drain_subscriptions(limit: 500)
    assert keys -- everything == []

    # The end of the walk is a nil cursor, not an empty page the caller has to
    # recognise for itself.
    {_rows, cursor} = Storage.list_subscriptions(nil, limit: 500)
    assert is_nil(cursor) or is_binary(cursor)

    :ok
  end

  defp subscription_keys(ctx), do: for(n <- 1..3, do: "#{ctx.storage_tenant}_sub#{n}")

  defp put_subscription!(key, status) do
    assert {:ok, _row} =
             Storage.put_subscription(%{tenant_key: key, plan_id: "free", status: status})
  end

  # Walks every page to the end, with a hard bound so a cursor that never
  # terminates fails here rather than hanging the suite.
  defp drain_subscriptions(opts) do
    Enum.reduce_while(1..1_000, {nil, []}, fn iteration, {cursor, acc} ->
      {rows, next} = Storage.list_subscriptions(cursor, opts)
      acc = acc ++ Enum.map(rows, & &1.tenant_key)

      cond do
        is_nil(next) -> {:halt, acc}
        iteration == 1_000 -> flunk("list_subscriptions/2's cursor never reached the end")
        true -> {:cont, {next, acc}}
      end
    end)
  end

  @doc false
  @spec assert_generations!(map()) :: :ok
  def assert_generations!(ctx) do
    durable(:projection_generations, fn ->
      assert {:ok, [{_event, :inserted}]} =
               Storage.record_events([entry(ctx, "generation", 5)], [])

      assert :ok =
               Storage.write_projection_totals(1, [
                 %{
                   tenant_key: ctx.storage_tenant,
                   feature: "storage_case",
                   period_start: ctx.storage_period,
                   quantity: 99,
                   events: 1
                 }
               ])

      # Still reading the active generation, which is not the one just written:
      # a reader never sees a half-built generation.
      assert total(ctx).quantity == 5

      active = active_generation()

      try do
        assert :ok = Storage.activate_projection(1)
        assert total(ctx).quantity == 99
      after
        Storage.activate_projection(active)
      end

      # The restore is asserted, not assumed (open-findings.md X97).
      assert active_generation() == active
    end)
  end

  @doc """
  One `t:AuroraMeter.Storage.event_entry/0` for the suite, already canonical.

  The `payload_hash` is computed with `AuroraMeter.Events.Canonical`, which is
  what the facade does, so an adapter cannot pass by inventing its own
  definition of "the same payload".
  """
  @spec entry(map(), String.t(), pos_integer()) :: AuroraMeter.Storage.event_entry()
  def entry(context, event_id, quantity) do
    attrs = %{
      feature: :storage_case,
      quantity: quantity,
      occurred_at: context.storage_at,
      kind: :usage,
      original_event_id: nil,
      dimensions: %{},
      metadata: %{}
    }

    %{
      tenant_key: context.storage_tenant,
      event_id: event_id,
      feature: "storage_case",
      quantity: quantity,
      kind: "usage",
      original_event_id: nil,
      occurred_at: context.storage_at,
      period_start: context.storage_period,
      period_source: "AuroraMeter.StorageCase",
      attribution: "resolved",
      dimensions: %{},
      metadata: %{},
      plan_id: nil,
      plan_version: nil,
      payload_hash: Canonical.payload_hash(attrs)
    }
  end

  @doc """
  One `t:AuroraMeter.Storage.correction_entry/0` for the suite.

  There is no `payload_hash` here on purpose: a correction's canonical tuple
  carries the original's feature, occurrence instant and dimensions, so only an
  adapter that has read the original can compute it. An adapter that invents
  its own definition of "the same correction" fails the duplicate and conflict
  assertions above.
  """
  @spec correction(map(), String.t(), String.t(), pos_integer() | :remaining) ::
          AuroraMeter.Storage.correction_entry()
  def correction(context, event_id, original_event_id, quantity) do
    %{
      tenant_key: context.storage_tenant,
      event_id: event_id,
      original_event_id: original_event_id,
      quantity: quantity,
      metadata: %{}
    }
  end

  @doc """
  The projected total for one generation, `%{quantity: 0, events: 0}` when the
  row is absent, without going through the active-generation indirection.
  """
  @spec generation_total(map(), integer()) :: %{quantity: integer(), events: integer()}
  def generation_total(ctx, generation) do
    import Ecto.Query, only: [from: 2]

    total =
      AuroraMeter.Config.repo().one(
        from(t in AuroraMeter.Schema.EventTotal,
          where:
            t.tenant_key == ^ctx.storage_tenant and t.feature == "storage_case" and
              t.period_start == ^ctx.storage_period and t.generation == ^generation,
          select: %{quantity: t.quantity, events: t.events}
        )
      )

    total || %{quantity: 0, events: 0}
  end

  @doc """
  Puts the projection state back to one active generation with nothing being
  built, for a suite that announced one.
  """
  @spec restore_projection!(non_neg_integer()) :: :ok
  def restore_projection!(active) do
    Storage.activate_projection(active)

    AuroraMeter.Config.repo().query!(
      """
      UPDATE aurora_meter_checkpoints
         SET cursor = cursor - 'building_generation' - 'watermark' - 'seed_generation'
                              - 'previous_generation'
       WHERE name = 'events_projection'
      """,
      []
    )

    :ok
  end

  @doc """
  The projection generation reads currently resolve to.

  The suite restores it after the generation test, because it is one row for
  the whole installation.
  """
  @spec active_generation() :: non_neg_integer()
  def active_generation do
    # `_absent` rather than `nil`: the checkpoint row is missing on a database
    # below core schema version 7, and `AuroraMeter.Checkpoints.get/2` answers
    # that with `nil`, but its success typing is a map and Dialyzer proves a
    # literal `nil` clause unreachable. The `cursor` column is
    # `NOT NULL DEFAULT '{}'::jsonb`, so it needs no `|| %{}` either.
    case AuroraMeter.Checkpoints.get("events_projection") do
      %{cursor: cursor} -> Map.get(cursor, "active_generation", 0)
      _absent -> 0
    end
  end

  # Every durable assertion is skipped, not failed, for an adapter that does not
  # declare the capability. The refusal itself is asserted by
  # `assert_undeclared_refused!/1`, so declining is proven rather than ignored.
  defp durable(extra \\ nil, fun) do
    if Storage.supports?(:durable_events) and (is_nil(extra) or Storage.supports?(extra)) do
      fun.()
    end

    :ok
  end

  defp corrections(fun), do: durable(:corrections, fun)

  defp total(ctx) do
    {:ok, total} =
      Storage.load_event_total(ctx.storage_tenant, :storage_case, ctx.storage_period)

    total
  end
end
