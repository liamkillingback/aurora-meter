defmodule AuroraMeter.TelemetryRedactionTest do
  @moduledoc """
  `AuroraMeter.Telemetry.redact/2`: the supported way for a host to put event
  metadata in a log line or a span attribute without carrying an identifier
  there with it.

  Every case is driven with the real metadata shape of a real event, taken from
  `AuroraMeter.Telemetry.events/0`, rather than with an invented map. A
  redaction rule tested only against keys somebody remembered is a rule that
  drops exactly the keys somebody remembered.
  """
  use ExUnit.Case, async: true

  alias AuroraMeter.Telemetry

  test "redact/1 drops every identifier on the ledger event by default" do
    metadata = %{
      tenant_key: "org_synthetic",
      reference: "ref_synthetic",
      category: :paid,
      duplicate: false,
      overrun: true,
      deferred: false
    }

    assert Telemetry.redact(metadata) == %{
             category: :paid,
             duplicate: false,
             overrun: true,
             deferred: false
           }
  end

  test "redact/1 drops every key of every catalogue event that must never be a tag" do
    # Driven from the catalogue, so a future event that adds a `_key` or an
    # `_id` is covered by this test on the day it is added rather than when
    # somebody remembers to extend a list here.
    kept =
      for entry <- Telemetry.events(),
          metadata = Map.new(entry.metadata, &{&1, "value"}),
          {key, _value} <- Telemetry.redact(metadata),
          key != :error_class,
          not Telemetry.tag_allowed?(key, true),
          key not in safe_correlation_keys(),
          do: {entry.event, key}

    assert kept == [],
           "redact/1 kept keys that must never leave the system:\n" <>
             Enum.map_join(kept, "\n", &inspect/1)
  end

  test "redact/2 with tenant: :digest emits a stable 16 character digest and never the key" do
    one = Telemetry.redact(%{tenant_key: "org_synthetic"}, tenant: :digest)
    again = Telemetry.redact(%{tenant_key: "org_synthetic"}, tenant: :digest)
    other = Telemetry.redact(%{tenant_key: "org_other"}, tenant: :digest)

    assert %{tenant_digest: digest} = one
    assert String.length(digest) == 16
    assert digest =~ ~r/^[0-9a-f]{16}$/
    assert one == again, "the digest must be stable, or it cannot correlate anything"
    refute one == other, "two tenants must not collapse into one series"
    refute Map.has_key?(one, :tenant_key)
    refute String.contains?(digest, "org_synthetic")
  end

  test "redact/2 with tenant: :raw is the only way to keep the tenant key" do
    assert Telemetry.redact(%{tenant_key: "org_synthetic"}, tenant: :raw) == %{
             tenant_key: "org_synthetic"
           }

    assert Telemetry.redact(%{tenant_key: "org_synthetic"}, tenant: :drop) == %{}
    assert Telemetry.redact(%{tenant_key: "org_synthetic"}) == %{}
  end

  test "redact/2 refuses an unknown :tenant option rather than silently dropping" do
    assert_raise ArgumentError, ~r/:tenant must be :drop, :digest or :raw/, fn ->
      Telemetry.redact(%{tenant_key: "org_synthetic"}, tenant: :hash)
    end
  end

  test "redact/1 replaces error with error_class and never carries the message" do
    assert Telemetry.redact(%{error: %RuntimeError{message: "SELECT secret FROM t"}}) == %{
             error_class: "RuntimeError"
           }

    assert Telemetry.redact(%{error: :timeout}) == %{error_class: :timeout}

    assert Telemetry.redact(%{error: {:unavailable, "detail with a key in it"}}) ==
             %{error_class: :unavailable}

    assert Telemetry.redact(%{error: "a bare string"}) == %{error_class: :unknown}
  end

  test "redact/1 never carries a stacktrace or a reason" do
    metadata = %{
      kind: :error,
      reason: %RuntimeError{message: "boom"},
      stacktrace: [{Foo, :bar, 1, []}]
    }

    assert Telemetry.redact(metadata) == %{kind: :error}
  end

  test "redact/1 leaves a bounded dimension alone, or it would not be usable" do
    assert Telemetry.redact(%{result: :inserted, kind: :usage, state: :pending}) ==
             %{result: :inserted, kind: :usage, state: :pending}
  end

  # Metadata keys that are neither tags nor identifiers: bounded enough to keep
  # in a log line, not bounded enough to be a metric tag. Each is named so the
  # exemption dies with the key rather than outliving it.
  defp safe_correlation_keys do
    [
      # booleans and small closed sets
      :declared,
      :duplicate,
      :overrun,
      :deferred,
      :blocked,
      :shadow,
      :category,
      :projection,
      :durability,
      :decision,
      :outcome,
      :phase,
      :counter_rows,
      :history_rows,
      :batch_size,
      # counts a phase reports
      :differences,
      :drained,
      :resumed,
      :seeded,
      # free-form but bounded by the host's own configuration, and useful in a
      # log line precisely because it says which thing stopped
      :operation,
      :name,
      :table,
      :node,
      :origin,
      :generation,
      :cursor,
      :period_start,
      # Version strings, bounded by the host's own plan definitions. Not tag
      # material, because only the host knows how many versions it has, and not
      # an identifier either: a log line saying which plan version a grant used
      # is the whole point of the log line.
      :plan_version,
      :from_version,
      :to_version
    ]
  end
end
