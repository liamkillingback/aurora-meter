defmodule AuroraMeter.RecordTest do
  @moduledoc """
  The contract of `AuroraMeter.record/4`: what it refuses, what it canonicalises
  and what it does with an identity it has seen before (build unit 03b).

  Everything here is a single-connection fact, so it runs on the sandbox. The
  concurrency and process-death halves of I06 and I07 need real connections and
  live in `AuroraMeter.RecordConcurrencyTest`.
  """
  use AuroraMeter.DataCase, async: false
  use ExUnitProperties

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Event
  alias AuroraMeter.Events
  alias AuroraMeter.Events.Canonical
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.IncapableStorage
  alias AuroraMeter.Test.PeriodSources
  alias AuroraMeter.Test.RecordingOutbox
  alias AuroraMeter.Test.UnresolvedStorage

  setup do
    AuroraMeter.Test.reset!()
    :ok = RecordingOutbox.start!()
    tenant = unique_tenant("record")
    %{tenant: tenant, at: DateTime.utc_now(), period: AuroraMeter.period(tenant).start}
  end

  # Build unit 07c: a tenant with no subscription has no commercial contract to
  # attribute usage to, so every event it records is stamped
  # `attribution: :plan_unresolved` and staged ineligible. A test that is about
  # something else (the feature source, the correction chain, the identity
  # rules) needs a tenant that a real host would have, which is one with an
  # assignment. It is subscribed here rather than in `setup` so the tests that
  # are about the unattributed tenant keep having one.
  defp subscribed!(tenant, plan \\ :free) do
    AuroraMeter.Test.subscribe_since!(tenant, plan, ~U[2020-01-01 00:00:00Z])
    tenant
  end

  defp record(tenant, opts) do
    feature = Keyword.get(opts, :feature, :ai_generations)
    quantity = Keyword.get(opts, :quantity, 1)

    AuroraMeter.record(
      tenant,
      feature,
      quantity,
      Keyword.drop(opts, [:feature, :quantity])
    )
  end

  defp event_count(tenant) do
    TestRepo.aggregate(
      from(e in AuroraMeter.Schema.Event, where: e.tenant_key == ^tenant),
      :count
    )
  end

  defp totals(tenant) do
    TestRepo.all(
      from(t in EventTotal, where: t.tenant_key == ^tenant, select: map(t, [:quantity, :events]))
    )
  end

  describe "validation, before any database call" do
    test "I07 record rejects a missing id, an oversized id and a reserved prefix", ctx do
      assert {:error, {:invalid, errors}} = record(ctx.tenant, occurred_at: ctx.at)
      assert {:id, :missing} in errors

      too_long = String.duplicate("x", 129)
      assert {:error, {:invalid, errors}} = record(ctx.tenant, id: too_long, occurred_at: ctx.at)
      assert {:id, :too_long} in errors

      for prefix <- Canonical.reserved_id_prefixes() do
        assert {:error, {:invalid, errors}} =
                 record(ctx.tenant, id: prefix <> "mine", occurred_at: ctx.at)

        assert {:id, :reserved_prefix} in errors
      end

      assert event_count(ctx.tenant) == 0
      assert RecordingOutbox.calls() == 0
    end

    test "I07 record rejects a non-UTF-8 id", ctx do
      invalid = <<0xFF, 0xFE, 0xFD>>
      refute String.valid?(invalid)

      assert {:error, {:invalid, errors}} = record(ctx.tenant, id: invalid, occurred_at: ctx.at)
      assert {:id, :not_utf8} in errors
    end

    test "record accepts a 128-byte Unicode id and rejects 129 bytes", ctx do
      # 32 four-byte characters: 128 bytes, 32 codepoints. The limit is
      # byte_size/1 and not String.length/1, and the two differ here by four.
      emoji = String.duplicate("\u{1F600}", 32)
      assert byte_size(emoji) == 128
      assert String.length(emoji) == 32

      assert {:ok, %Event{}, :inserted} = record(ctx.tenant, id: emoji, occurred_at: ctx.at)

      over = emoji <> "x"
      assert byte_size(over) == 129
      assert {:error, {:invalid, errors}} = record(ctx.tenant, id: over, occurred_at: ctx.at)
      assert {:id, :too_long} in errors
    end

    test "record rejects a float, zero, a negative and an out-of-range quantity", ctx do
      for {quantity, reason} <- [
            {1.0, :not_a_positive_integer},
            {0, :not_a_positive_integer},
            {-3, :not_a_positive_integer},
            {Canonical.quantity_max() + 1, :out_of_range}
          ] do
        assert {:error, {:invalid, errors}} =
                 record(ctx.tenant,
                   id: "q-#{inspect(quantity)}",
                   quantity: quantity,
                   occurred_at: ctx.at
                 )

        assert {:quantity, reason} in errors, "#{inspect(quantity)} gave #{inspect(errors)}"
      end

      assert event_count(ctx.tenant) == 0
    end

    test "record rejects an occurred_at beyond the future tolerance and accepts one inside it",
         ctx do
      frozen = ~U[2026-05-05 12:00:00.000000Z]

      AuroraMeter.Test.with_clock(frozen, fn ->
        inside = DateTime.add(frozen, 299, :second)
        outside = DateTime.add(frozen, 301, :second)

        assert {:ok, %Event{}, :inserted} = record(ctx.tenant, id: "inside", occurred_at: inside)

        assert {:error, {:invalid, errors}} =
                 record(ctx.tenant, id: "outside", occurred_at: outside)

        assert {:occurred_at, :future} in errors

        # And the tolerance is a per-call option as well as a setting.
        assert {:ok, %Event{}, :inserted} =
                 record(ctx.tenant, id: "widened", occurred_at: outside, future_tolerance: 600)
      end)
    end

    test "record rejects an occurred_at that is not a UTC DateTime", ctx do
      assert {:error, {:invalid, errors}} =
               record(ctx.tenant, id: "naive", occurred_at: ~N[2026-05-05 12:00:00])

      assert {:occurred_at, :not_a_datetime} in errors
    end

    test "record rejects atom keys, non-JSON-safe values and the dimension limits", ctx do
      cases = [
        {[dimensions: %{model: "sonnet"}], {:dimensions, :non_string_key}},
        {[dimensions: %{"model" => {:a, :tuple}}], {:dimensions, :non_scalar_value}},
        {[dimensions: %{"model" => %{"nested" => 1}}], {:dimensions, :non_scalar_value}},
        {[dimensions: Map.new(1..33, &{"k#{&1}", 1})], {:dimensions, :too_many_keys}},
        {[dimensions: %{String.duplicate("k", 65) => 1}], {:dimensions, :key_too_long}},
        {[dimensions: %{"k" => String.duplicate("v", 257)}], {:dimensions, :value_too_long}},
        {[metadata: %{note: "atom key"}], {:metadata, :non_string_key}},
        {[metadata: %{"pid" => self()}], {:metadata, :not_json_encodable}},
        {[metadata: %{"blob" => String.duplicate("m", 16 * 1024)}], {:metadata, :too_large}}
      ]

      for {opts, expected} <- cases do
        id = "dim-#{System.unique_integer([:positive])}"

        assert {:error, {:invalid, errors}} =
                 record(ctx.tenant, [id: id, occurred_at: ctx.at] ++ opts)

        assert expected in errors, "#{inspect(opts)} gave #{inspect(errors)}"
      end

      assert event_count(ctx.tenant) == 0
      assert RecordingOutbox.calls() == 0
    end

    test "record accepts the largest dimension set and metadata that are still legal", ctx do
      dimensions = Map.new(1..32, &{"k#{&1}", String.duplicate("v", 256)})
      metadata = %{"blob" => String.duplicate("m", 16 * 1024 - 20)}

      assert {:ok, %Event{}, :inserted} =
               record(ctx.tenant,
                 id: "at-the-limit",
                 occurred_at: ctx.at,
                 dimensions: dimensions,
                 metadata: metadata
               )
    end

    test "record rejects an empty tenant key", _ctx do
      assert {:error, {:invalid, errors}} =
               AuroraMeter.record("", :ai_generations, 1,
                 id: "empty-tenant",
                 occurred_at: DateTime.utc_now()
               )

      assert {:tenant, :empty} in errors
    end

    test "record raises ArgumentError for a binary feature", ctx do
      assert_raise ArgumentError, fn ->
        AuroraMeter.record(ctx.tenant, "ai_generations", 1, id: "s", occurred_at: ctx.at)
      end
    end

    test "record denies an undeclared feature under :deny and raises under :raise", ctx do
      TestConfig.with_config([{:aurora_meter, :undeclared_feature_policy, :deny}], fn ->
        assert {:error, {:invalid, [feature: :undeclared]}} =
                 record(ctx.tenant, feature: :nowhere, id: "u1", occurred_at: ctx.at)
      end)

      TestConfig.with_config([{:aurora_meter, :undeclared_feature_policy, :raise}], fn ->
        assert_raise AuroraMeter.UndeclaredFeatureError, fn ->
          record(ctx.tenant, feature: :nowhere, id: "u2", occurred_at: ctx.at)
        end
      end)

      assert event_count(ctx.tenant) == 0
    end
  end

  describe "the canonical payload" do
    test "I07 canonical json sorts keys recursively" do
      assert Canonical.canonical_json(%{"b" => 1, "a" => %{"z" => 1, "y" => 2}}) ==
               ~s({"a":{"y":2,"z":1},"b":1})

      assert Canonical.canonical_json(%{"a" => 1, "b" => 2}) ==
               Canonical.canonical_json(%{"b" => 2, "a" => 1})
    end

    test "I07 map key ordering does not change the payload hash", ctx do
      first = %{"zebra" => "z", "alpha" => "a", "middle" => "m"}
      second = %{"middle" => "m", "alpha" => "a", "zebra" => "z"}

      attrs = %{feature: :ai_generations, quantity: 1, occurred_at: ctx.at, kind: :usage}

      assert Canonical.payload_hash(Map.put(attrs, :metadata, first)) ==
               Canonical.payload_hash(Map.put(attrs, :metadata, second))

      assert {:ok, %Event{}, :inserted} =
               record(ctx.tenant, id: "order", occurred_at: ctx.at, metadata: first)

      assert {:ok, %Event{}, :duplicate} =
               record(ctx.tenant, id: "order", occurred_at: ctx.at, metadata: second)

      assert event_count(ctx.tenant) == 1
    end

    test "the canonical encoding is a JSON array, which no field value can impersonate" do
      # A value that contains the delimiter is escaped by JSON itself, so it
      # cannot merge two elements into one. Two different splits of the same
      # characters must hash differently.
      base = %{
        feature: :f,
        quantity: 1,
        occurred_at: ~U[2026-01-01 00:00:00.000000Z],
        kind: :usage
      }

      a = Canonical.payload_hash(Map.put(base, :metadata, %{"a" => ~s(x","y)}))
      b = Canonical.payload_hash(Map.put(base, :metadata, %{"a" => "x", "y" => ""}))

      refute a == b
    end

    test "the hash is taken over the microsecond value the column stores", ctx do
      # The column is timestamp(6). A nanosecond-bearing input must hash the
      # value that will be stored, or reading the row back would compute a
      # different hash and a retry would look like a conflict.
      nanos = %{ctx.at | microsecond: {123_456, 6}}

      assert {:ok, event, :inserted} = record(ctx.tenant, id: "usec", occurred_at: nanos)
      assert event.occurred_at.microsecond == {123_456, 6}

      assert {:ok, _event, :duplicate} = record(ctx.tenant, id: "usec", occurred_at: nanos)
    end
  end

  describe "identity" do
    test "recording writes one row, one totals delta and one outbox item", ctx do
      subscribed!(ctx.tenant)

      TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        assert {:ok, event, :inserted} =
                 record(ctx.tenant, id: "one", occurred_at: DateTime.utc_now(), quantity: 7)

        assert event.event_id == "one"
        assert event.tenant_key == ctx.tenant
        assert event.feature == :ai_generations
        assert event.quantity == 7
        assert event.kind == :usage
        assert event.durability == :durable
        assert event.attribution == :resolved
        assert is_integer(event.seq)

        assert event_count(ctx.tenant) == 1
        assert totals(ctx.tenant) == [%{quantity: 7, events: 1}]
        assert [%{event: %Event{event_id: "one"}}] = RecordingOutbox.items()
      end)
    end

    test "I06 a retry with the same id and payload is a duplicate with no second effect", ctx do
      TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        assert {:ok, first, :inserted} =
                 record(ctx.tenant, id: "retry", occurred_at: ctx.at, quantity: 5)

        assert {:ok, second, :duplicate} =
                 record(ctx.tenant, id: "retry", occurred_at: ctx.at, quantity: 5)

        assert second.id == first.id
        assert second.seq == first.seq
        assert event_count(ctx.tenant) == 1
        assert totals(ctx.tenant) == [%{quantity: 5, events: 1}]
        assert length(RecordingOutbox.items()) == 1
      end)
    end

    test "I07 a changed quantity, occurred_at, feature, dimension or metadata value each conflict",
         ctx do
      base = [
        id: "conflict",
        occurred_at: ctx.at,
        quantity: 2,
        dimensions: %{"model" => "sonnet"},
        metadata: %{"trace" => "t1"}
      ]

      assert {:ok, original, :inserted} = record(ctx.tenant, base)

      changes = [
        {:quantity, Keyword.put(base, :quantity, 3)},
        {:occurred_at, Keyword.put(base, :occurred_at, DateTime.add(ctx.at, -60, :second))},
        {:feature, Keyword.put(base, :feature, :requests)},
        {:dimensions, Keyword.put(base, :dimensions, %{"model" => "opus"})},
        {:metadata, Keyword.put(base, :metadata, %{"trace" => "t2"})}
      ]

      for {field, opts} <- changes do
        assert {:error, {:conflict, existing}} = record(ctx.tenant, opts),
               "changing #{field} did not conflict"

        assert existing.event_id == "conflict"
        assert existing.quantity == original.quantity
        assert existing.occurred_at == original.occurred_at
        assert existing.metadata == %{"trace" => "t1"}
      end

      assert event_count(ctx.tenant) == 1
      assert totals(ctx.tenant) == [%{quantity: 2, events: 1}]
    end

    test "I06 the same id in two tenants creates two events", ctx do
      other = unique_tenant("record")

      assert {:ok, _one, :inserted} = record(ctx.tenant, id: "shared", occurred_at: ctx.at)
      assert {:ok, _two, :inserted} = record(other, id: "shared", occurred_at: ctx.at)

      assert event_count(ctx.tenant) == 1
      assert event_count(other) == 1
    end

    test "I07 the same id for two features in one tenant conflicts", ctx do
      assert {:ok, _event, :inserted} =
               record(ctx.tenant, feature: :ai_generations, id: "per-tenant", occurred_at: ctx.at)

      assert {:error, {:conflict, existing}} =
               record(ctx.tenant, feature: :requests, id: "per-tenant", occurred_at: ctx.at)

      assert existing.feature == :ai_generations
      assert event_count(ctx.tenant) == 1
    end
  end

  describe "period attribution" do
    test "record accepts an occurred_at from a previous period and resolves its period", ctx do
      subscribed!(ctx.tenant)
      last_month = ~U[2026-05-15 09:00:00.000000Z]

      AuroraMeter.Test.with_clock(~U[2026-06-10 12:00:00.000000Z], fn ->
        assert {:ok, event, :inserted} = record(ctx.tenant, id: "late", occurred_at: last_month)

        assert event.period_start == ~U[2026-05-01 00:00:00Z]
        assert event.attribution == :resolved

        # Build unit 07c: the plan half of the same stamp. The tenant's
        # assignment started in 2020, so a May 2026 instant is inside it.
        assert event.plan_id == "free"
        assert event.plan_version == "1"
      end)
    end

    test "a period source that cannot place the instant records attribution unresolved", ctx do
      TestConfig.with_config(
        [{:aurora_meter, :period_source, PeriodSources.FutureWindow}],
        fn ->
          assert {:ok, event, :inserted} =
                   record(ctx.tenant, id: "unresolved", occurred_at: ctx.at)

          assert event.attribution == :unresolved
          assert event.period_start == truncate_month(ctx.at)
        end
      )
    end

    test "an unresolved event is ineligible for export", ctx do
      TestConfig.with_config(
        [
          {:aurora_meter, :events_outbox, RecordingOutbox},
          {:aurora_meter, :period_source, PeriodSources.FutureWindow}
        ],
        fn ->
          assert {:ok, _event, :inserted} =
                   record(ctx.tenant, id: "ineligible", occurred_at: ctx.at)

          assert [%{eligibility: {:ineligible, :attribution_unresolved}}] =
                   RecordingOutbox.items()
        end
      )
    end

    test "an events-source feature is eligible and a buffered one is not", ctx do
      subscribed!(ctx.tenant)
      at = DateTime.utc_now()

      TestConfig.with_config(
        [
          {:aurora_meter, :events_outbox, RecordingOutbox},
          {:aurora_meter, :feature_sources, %{ai_generations: :events}}
        ],
        fn ->
          assert {:ok, _event, :inserted} =
                   record(ctx.tenant, feature: :ai_generations, id: "e1", occurred_at: at)

          assert {:ok, _event, :inserted} =
                   record(ctx.tenant, feature: :requests, id: "b1", occurred_at: at)

          assert [%{eligibility: :eligible}, %{eligibility: {:ineligible, :feature_buffered}}] =
                   RecordingOutbox.items()
        end
      )
    end
  end

  describe "the outbox seam" do
    test "an outbox error rolls the whole record back", ctx do
      TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        RecordingOutbox.fail!(:staging_unavailable)

        assert {:error, {:unavailable, {:outbox, :staging_unavailable}}} =
                 record(ctx.tenant, id: "outbox-error", occurred_at: ctx.at)

        assert event_count(ctx.tenant) == 0
        assert totals(ctx.tenant) == []
      end)
    end

    test "an outbox that raises rolls the whole record back", ctx do
      TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        RecordingOutbox.raise!("outbox exploded")

        assert {:error, {:unavailable, _reason}} =
                 record(ctx.tenant, id: "outbox-raise", occurred_at: ctx.at)

        assert event_count(ctx.tenant) == 0
        assert totals(ctx.tenant) == []
      end)
    end

    test "a duplicate stages no second intent", ctx do
      TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        assert {:ok, _event, :inserted} = record(ctx.tenant, id: "once", occurred_at: ctx.at)
        assert {:ok, _event, :duplicate} = record(ctx.tenant, id: "once", occurred_at: ctx.at)

        assert length(RecordingOutbox.items()) == 1
      end)
    end
  end

  describe "capability" do
    test "record returns {:error, {:unsupported, :durable_events}} for an adapter without it",
         ctx do
      TestConfig.with_config(
        [{:aurora_meter, :storage, IncapableStorage}],
        fn ->
          assert {:error, {:unsupported, :durable_events}} =
                   record(ctx.tenant, id: "no-cap", occurred_at: ctx.at)
        end
      )
    end

    test "an adapter that cannot resolve a conflict says so rather than guessing", ctx do
      # Measured in docs/evidence/v1/phase-03/03b-conflict-wait.md: no race on
      # PostgreSQL 16.13 reaches the adapter's own branch through
      # ON CONFLICT alone, but a concurrent DELETE of the conflicting row does.
      # This asserts the contract the caller sees either way: the answer is
      # "unknown, retry with the same id", never a guessed duplicate.
      TestConfig.with_config(
        [{:aurora_meter, :storage, UnresolvedStorage}],
        fn ->
          assert {:error, {:unavailable, :conflict_unresolved}} =
                   record(ctx.tenant, id: "unknowable", occurred_at: ctx.at)
        end
      )
    end
  end

  describe "the read API" do
    test "Events.get, total and count read back what was recorded", ctx do
      assert {:ok, event, :inserted} =
               record(ctx.tenant, id: "readback", occurred_at: ctx.at, quantity: 4)

      assert {:ok, read} = Events.get(ctx.tenant, "readback")
      assert read.id == event.id
      assert read.quantity == 4

      assert Events.get(ctx.tenant, "no-such-id") == {:error, :not_found}
      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 4
      assert Events.count(ctx.tenant, :ai_generations, ctx.period) == %{quantity: 4, events: 1}
    end

    test "Events.stream pages by seq, not by id", ctx do
      for n <- 1..5 do
        assert {:ok, _event, :inserted} = record(ctx.tenant, id: "s#{n}", occurred_at: ctx.at)
      end

      seqs =
        [tenant: ctx.tenant, limit: 2]
        |> Events.stream()
        |> Enum.map(& &1.seq)

      assert length(seqs) == 5
      assert seqs == Enum.sort(seqs)
    end
  end

  describe "the canonical encoder, as a property" do
    # The encoder is the definition of "the same payload", so the property that
    # matters is injectivity: two payloads that differ anywhere must not encode
    # to the same bytes, or a conflicting reuse of an identity would be accepted
    # as a duplicate. `AURORA_PROPERTY_RUNS` raises the sample in the seeded
    # runner without slowing the ordinary edit loop.
    property "I07 two different payloads never share an encoding, and key order never changes one" do
      check all(payload <- payload_generator(), max_runs: property_runs()) do
        shuffled = shuffle_keys(payload)

        assert Canonical.canonical_json(payload) == Canonical.canonical_json(shuffled)
        assert Canonical.payload_hash(attrs(payload)) == Canonical.payload_hash(attrs(shuffled))

        changed = change(payload)

        if changed != payload do
          refute Canonical.canonical_json(payload) == Canonical.canonical_json(changed)
          refute Canonical.payload_hash(attrs(payload)) == Canonical.payload_hash(attrs(changed))
        end
      end
    end

    property "the encoding of the tuple is stable across every field" do
      check all(
              quantity <- StreamData.positive_integer(),
              feature <- StreamData.member_of([:a, :bb, :ccc]),
              micros <- StreamData.integer(0..999_999),
              max_runs: property_runs()
            ) do
        base = %{
          feature: feature,
          quantity: quantity,
          occurred_at: %{~U[2026-01-01 00:00:00.000000Z] | microsecond: {micros, 6}},
          kind: :usage,
          original_event_id: nil,
          dimensions: %{},
          metadata: %{}
        }

        hash = Canonical.payload_hash(base)

        assert Canonical.payload_hash(base) == hash
        refute Canonical.payload_hash(%{base | quantity: quantity + 1}) == hash

        refute Canonical.payload_hash(%{base | kind: :correction}) == hash

        refute Canonical.payload_hash(%{
                 base
                 | occurred_at: DateTime.add(base.occurred_at, 1, :microsecond)
               }) == hash
      end
    end
  end

  defp property_runs do
    case System.get_env("AURORA_PROPERTY_RUNS") do
      nil -> 100
      "" -> 100
      value -> String.to_integer(value)
    end
  end

  defp payload_generator do
    StreamData.map_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 6),
      StreamData.one_of([
        StreamData.string(:alphanumeric, max_length: 8),
        StreamData.integer(),
        StreamData.boolean(),
        StreamData.constant(nil)
      ]),
      max_length: 6
    )
  end

  defp shuffle_keys(map), do: map |> Enum.shuffle() |> Map.new()

  defp change(map) when map_size(map) == 0, do: %{"added" => 1}

  defp change(map) do
    {key, value} = map |> Enum.sort() |> hd()
    Map.put(map, key, {:changed, value} |> :erlang.phash2() |> Integer.to_string())
  end

  defp attrs(metadata) do
    %{
      feature: :ai_generations,
      quantity: 1,
      occurred_at: ~U[2026-01-01 00:00:00.000000Z],
      kind: :usage,
      original_event_id: nil,
      dimensions: %{},
      metadata: metadata
    }
  end

  defp truncate_month(instant) do
    instant
    |> DateTime.to_date()
    |> Date.beginning_of_month()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end
end
