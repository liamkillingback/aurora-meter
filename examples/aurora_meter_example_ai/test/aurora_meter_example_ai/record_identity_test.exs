defmodule AuroraMeterExampleAi.RecordIdentityTest do
  @moduledoc """
  What `AuroraMeter.record/4`'s identity actually covers, asserted from a host's
  side rather than read off the documentation.

  This exists because the sample's recovery path was written twice. The first
  version retried `record/4` with the same id to ask "did this already commit",
  which is what the library's own documentation describes as always safe, and it
  came back as a **conflict** every time. The reason is in this file: the
  payload identity includes `occurred_at` to the microsecond, and a caller
  retrying after a crash cannot reproduce the instant at which it first called.

  "Retry with the same id" is therefore "retry with the same id and the same
  payload", and that is a real constraint on a host's design: either persist the
  payload before you record it, or keep your own durable trace of what you
  recorded. The `AuroraMeter.Events.Outbox` seam gives a host the second one for
  nothing, which is what this sample uses.
  """
  use AuroraMeterExampleAi.DataCase, async: false
  use AuroraMeter.Test, reset: true

  alias AuroraMeterExampleAi.SampleFixtures

  setup do
    %{org: SampleFixtures.org_fixture()}
  end

  defp opts(overrides) do
    Keyword.merge(
      [
        id: "probe:" <> Ecto.UUID.generate(),
        occurred_at: DateTime.utc_now(),
        dimensions: %{"model" => "nimbus-1"},
        metadata: %{}
      ],
      overrides
    )
  end

  test "the same id with the same payload is a duplicate", %{org: org} do
    o = opts([])
    assert {:ok, first, :inserted} = AuroraMeter.record(org, :tokens, 10, o)
    assert {:ok, second, :duplicate} = AuroraMeter.record(org, :tokens, 10, o)
    assert second.event_id == first.event_id
  end

  test "the same id with a later occurred_at is a CONFLICT, not a duplicate", %{org: org} do
    o = opts([])
    assert {:ok, _first, :inserted} = AuroraMeter.record(org, :tokens, 10, o)

    later = Keyword.put(o, :occurred_at, DateTime.add(o[:occurred_at], 1, :microsecond))
    assert {:error, {:conflict, existing}} = AuroraMeter.record(org, :tokens, 10, later)
    assert existing.event_id == o[:id]
  end

  test "the same id with a different quantity is a conflict", %{org: org} do
    o = opts([])
    assert {:ok, _first, :inserted} = AuroraMeter.record(org, :tokens, 10, o)
    assert {:error, {:conflict, _}} = AuroraMeter.record(org, :tokens, 11, o)
  end

  test "the same id with different dimensions is a conflict", %{org: org} do
    o = opts([])
    assert {:ok, _first, :inserted} = AuroraMeter.record(org, :tokens, 10, o)

    assert {:error, {:conflict, _}} =
             AuroraMeter.record(
               org,
               :tokens,
               10,
               Keyword.put(o, :dimensions, %{"model" => "nimbus-1-mini"})
             )
  end

  test "the prompt is not part of the identity, because the prompt is not in the event", %{
    org: org
  } do
    # The boundary this sample cares about most. Two entirely different customer
    # requests that happen to produce the same token count, model and instant
    # are ONE fact as far as the metering system is concerned, and it is right
    # about that: it is metering tokens, not text. Deciding that they are
    # different requests is the host's, which is why the sample compares the
    # prompt itself in `AuroraMeterExampleAi.Generations`.
    o = opts([])
    assert {:ok, _first, :inserted} = AuroraMeter.record(org, :tokens, 10, o)
    assert {:ok, _second, :duplicate} = AuroraMeter.record(org, :tokens, 10, o)
  end

  test "an unavailable answer is retryable with the same id when the payload is kept", %{org: org} do
    # The property the documentation promises, stated as a host would use it:
    # keep the option list, retry with the same list.
    o = opts([])
    assert {:ok, _e, :inserted} = AuroraMeter.record(org, :tokens, 42, o)
    assert {:ok, _e, :duplicate} = AuroraMeter.record(org, :tokens, 42, o)
    assert {:ok, _e, :duplicate} = AuroraMeter.record(org, :tokens, 42, o)
  end
end
