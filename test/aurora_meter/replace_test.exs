defmodule AuroraMeter.ReplaceTest do
  @moduledoc """
  `AuroraMeter.replace/4`: a full reversal of one fact plus a replacement for
  it, in one transaction (build unit 03e).

  This is how a **dimension or a timestamp** is corrected, and the reason it is
  a separate function is that neither can be corrected by reducing a quantity.
  Two rows and two export intents, or neither of them.
  """
  use AuroraMeter.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Event
  alias AuroraMeter.Events
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.RecordingOutbox

  setup do
    AuroraMeter.Test.reset!()
    :ok = RecordingOutbox.start!()
    tenant = unique_tenant("replace")
    at = ~U[2026-09-10 12:00:00.000000Z]
    %{tenant: tenant, at: at, period: AuroraMeter.period(tenant).start}
  end

  defp record(ctx, id, quantity, opts \\ []) do
    AuroraMeter.record(ctx.tenant, :ai_generations, quantity,
      id: id,
      occurred_at: Keyword.get(opts, :occurred_at, ctx.at),
      dimensions: Keyword.get(opts, :dimensions, %{})
    )
  end

  defp rows(tenant) do
    TestRepo.all(
      from(e in AuroraMeter.Schema.Event,
        where: e.tenant_key == ^tenant,
        order_by: [asc: e.seq],
        select: map(e, [:event_id, :quantity, :kind, :original_event_id, :dimensions])
      )
    )
  end

  defp totals(tenant) do
    TestRepo.all(
      from(t in EventTotal,
        where: t.tenant_key == ^tenant,
        order_by: [asc: t.period_start],
        select: map(t, [:period_start, :quantity, :events])
      )
    )
  end

  describe "the two rows" do
    test "replace fully corrects the original and records the replacement in one transaction",
         ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10, dimensions: %{"model" => "hai"})

      assert {:ok, %{correction: correction, replacement: replacement}, :inserted} =
               AuroraMeter.replace(
                 ctx.tenant,
                 "base",
                 %{quantity: 7, occurred_at: ctx.at, dimensions: %{"model" => "opus"}},
                 id: "fix"
               )

      assert correction.event_id == "fix"
      assert correction.kind == :correction
      assert correction.quantity == 10
      assert correction.original_event_id == "base"
      assert correction.dimensions == %{"model" => "hai"}

      assert replacement.event_id == "fix~r"
      assert replacement.kind == :usage
      assert replacement.quantity == 7
      assert replacement.dimensions == %{"model" => "opus"}
      assert replacement.feature == :ai_generations

      # original - original + replacement.
      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 7
      assert [%{quantity: 7, events: 3}] = totals(ctx.tenant)
      assert length(rows(ctx.tenant)) == 3
    end

    test "replace stages two intents, correction first", ctx do
      # Build unit 07c: eligibility carries the plan stamp too, and an
      # unattributed tenant is staged `{:ineligible, :plan_unresolved}` whatever
      # its feature source says. This test is about the ORDER of the two rows,
      # so the tenant gets the assignment a real host would have.
      AuroraMeter.Test.subscribe_since!(ctx.tenant, :free, ~U[2020-01-01 00:00:00Z])

      TestConfig.with_config(
        [
          {:aurora_meter, :events_outbox, RecordingOutbox},
          {:aurora_meter, :feature_sources, %{ai_generations: :events}}
        ],
        fn ->
          assert {:ok, _event, :inserted} = record(ctx, "base", 10)

          assert {:ok, _pair, :inserted} =
                   AuroraMeter.replace(ctx.tenant, "base", %{quantity: 7, occurred_at: ctx.at},
                     id: "fix"
                   )

          assert [_usage, correction, replacement] = RecordingOutbox.items()

          # An exporter that must cancel before re-sending sees them this way
          # round, which is why the order is asserted rather than the set.
          assert correction.event.kind == :correction
          assert replacement.event.kind == :usage
          assert correction.eligibility == :eligible
          assert replacement.eligibility == :eligible
        end
      )
    end

    test "the replacement's occurred_at may differ from the original's", ctx do
      assert {:ok, original, :inserted} = record(ctx, "base", 4)
      later = ~U[2026-09-11 08:00:00.000000Z]

      assert {:ok, %{correction: correction, replacement: replacement}, :inserted} =
               AuroraMeter.replace(ctx.tenant, "base", %{quantity: 4, occurred_at: later},
                 id: "fix"
               )

      # The correction inherits the ORIGINAL's instant, because it reverses the
      # original; the replacement carries the caller's new one.
      assert correction.occurred_at == original.occurred_at
      assert replacement.occurred_at == later
    end

    test "an unattributed pair names the right row in each reason", ctx do
      # The correction inherits the original's unresolved attribution, so its
      # reason is about the ORIGINAL. The replacement resolved its own period
      # from the caller's new occurred_at, so an unresolved attribution there is
      # its own problem and is named as such. Matching `kind` before
      # `attribution` is what keeps the two apart.
      TestConfig.with_config(
        [
          {:aurora_meter, :events_outbox, RecordingOutbox},
          {:aurora_meter, :period_source, AuroraMeter.Test.PeriodSources.FutureWindow},
          {:aurora_meter, :feature_sources, %{ai_generations: :events}}
        ],
        fn ->
          assert {:ok, original, :inserted} = record(ctx, "base", 10)
          assert original.attribution == :unresolved
          RecordingOutbox.reset!()

          assert {:ok, _pair, :inserted} =
                   AuroraMeter.replace(ctx.tenant, "base", %{quantity: 7, occurred_at: ctx.at},
                     id: "fix"
                   )

          assert [correction, replacement] = RecordingOutbox.items()
          assert correction.eligibility == {:ineligible, :original_ineligible}
          assert replacement.eligibility == {:ineligible, :attribution_unresolved}
        end
      )
    end

    test "an overridden replacement_id is used", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 4)

      assert {:ok, %{replacement: replacement}, :inserted} =
               AuroraMeter.replace(ctx.tenant, "base", %{quantity: 4, occurred_at: ctx.at},
                 id: "fix",
                 replacement_id: "brand-new"
               )

      assert replacement.event_id == "brand-new"
    end
  end

  describe "idempotence" do
    test "replace is idempotent under one caller id", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)

      attrs = %{quantity: 7, occurred_at: ctx.at}
      assert {:ok, first, :inserted} = AuroraMeter.replace(ctx.tenant, "base", attrs, id: "fix")
      assert {:ok, second, :duplicate} = AuroraMeter.replace(ctx.tenant, "base", attrs, id: "fix")

      assert second.correction.id == first.correction.id
      assert second.replacement.id == first.replacement.id

      assert length(rows(ctx.tenant)) == 3
      assert [%{quantity: 7, events: 3}] = totals(ctx.tenant)
    end

    test "a retry with an overridden replacement_id that differs conflicts", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      attrs = %{quantity: 7, occurred_at: ctx.at}

      assert {:ok, _pair, :inserted} = AuroraMeter.replace(ctx.tenant, "base", attrs, id: "fix")

      # The correction id is held and matches; the replacement id is not held at
      # all. There is no honest outcome for half a pairing.
      assert {:error, {:conflict, _existing}} =
               AuroraMeter.replace(ctx.tenant, "base", attrs, id: "fix", replacement_id: "other")

      assert length(rows(ctx.tenant)) == 3
    end
  end

  describe "refusals" do
    test "replace on a partially corrected original corrects only the remaining magnitude", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 4, id: "part")

      assert {:ok, %{correction: correction}, :inserted} =
               AuroraMeter.replace(ctx.tenant, "base", %{quantity: 3, occurred_at: ctx.at},
                 id: "fix"
               )

      assert correction.quantity == 6
      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 3
    end

    test "replace on a fully corrected original is already_fully_corrected", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, "base", 10, id: "all")

      assert AuroraMeter.replace(ctx.tenant, "base", %{quantity: 3, occurred_at: ctx.at},
               id: "fix"
             ) == {:error, {:invalid, [quantity: :already_fully_corrected]}}

      assert length(rows(ctx.tenant)) == 2
    end

    test "replace with a changed feature is rejected", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)

      assert AuroraMeter.replace(
               ctx.tenant,
               "base",
               %{quantity: 3, occurred_at: ctx.at, feature: :requests},
               id: "fix"
             ) == {:error, {:invalid, [feature: :differs_from_original]}}

      assert length(rows(ctx.tenant)) == 1
    end

    test "replace with the same feature stated explicitly is accepted", ctx do
      # The negative control for the refusal above (open-findings.md X84).
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)

      assert {:ok, _pair, :inserted} =
               AuroraMeter.replace(
                 ctx.tenant,
                 "base",
                 %{quantity: 3, occurred_at: ctx.at, feature: :ai_generations},
                 id: "fix"
               )
    end

    test "replace of a missing original is not_found", ctx do
      assert AuroraMeter.replace(ctx.tenant, "nope", %{quantity: 1, occurred_at: ctx.at},
               id: "fix"
             ) == {:error, {:not_found, :original}}
    end

    test "a caller id that leaves no room for the derived one is refused by name", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)
      id = String.duplicate("x", 127)

      assert AuroraMeter.replace(ctx.tenant, "base", %{quantity: 1, occurred_at: ctx.at}, id: id) ==
               {:error, {:invalid, [id: :too_long_for_replacement]}}

      # 126 is the last one that fits, and it works.
      fits = String.duplicate("y", 126)

      assert {:ok, %{replacement: replacement}, :inserted} =
               AuroraMeter.replace(ctx.tenant, "base", %{quantity: 1, occurred_at: ctx.at},
                 id: fits
               )

      assert byte_size(replacement.event_id) == 128
    end

    test "the replacement's own attributes are validated", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)

      assert {:error, {:invalid, errors}} =
               AuroraMeter.replace(ctx.tenant, "base", %{quantity: 0, occurred_at: ctx.at},
                 id: "fix"
               )

      assert {:quantity, :not_a_positive_integer} in errors
      assert length(rows(ctx.tenant)) == 1
    end
  end

  describe "atomicity" do
    test "a failure inserting the replacement rolls the correction back too", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)

      # The replacement id is already held by a different fact, so the insert of
      # the pair resolves to a conflict on the second row. The correction was in
      # the same statement; if it survived, `replace/4` would not be atomic.
      assert {:ok, _held, :inserted} = record(ctx, "fix~r", 99)

      assert {:error, {:conflict, existing}} =
               AuroraMeter.replace(ctx.tenant, "base", %{quantity: 7, occurred_at: ctx.at},
                 id: "fix"
               )

      assert existing.event_id == "fix~r"
      assert existing.quantity == 99

      assert Enum.map(rows(ctx.tenant), & &1.event_id) == ["base", "fix~r"]
      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 109
    end

    test "an outbox that refuses rolls both rows back", ctx do
      TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        assert {:ok, _event, :inserted} = record(ctx, "base", 10)
        RecordingOutbox.fail!(:staging_unavailable)

        assert AuroraMeter.replace(ctx.tenant, "base", %{quantity: 7, occurred_at: ctx.at},
                 id: "fix"
               ) == {:error, {:unavailable, {:outbox, :staging_unavailable}}}

        assert length(rows(ctx.tenant)) == 1
        assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 10
      end)
    end

    test "inside a host transaction both rows are conditional and roll back with it", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 10)

      assert {:error, :host_said_no} =
               TestRepo.transaction(fn ->
                 assert {:ok, %{correction: c, replacement: r}, :inserted} =
                          AuroraMeter.replace(
                            ctx.tenant,
                            "base",
                            %{quantity: 7, occurred_at: ctx.at},
                            id: "fix"
                          )

                 assert c.durability == :conditional
                 assert r.durability == :conditional
                 TestRepo.rollback(:host_said_no)
               end)

      assert length(rows(ctx.tenant)) == 1
      assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 10
    end
  end

  describe "the event struct" do
    test "both rows come back as AuroraMeter.Event structs with their own ids", ctx do
      assert {:ok, _event, :inserted} = record(ctx, "base", 5)

      assert {:ok, %{correction: %Event{} = c, replacement: %Event{} = r}, :inserted} =
               AuroraMeter.replace(ctx.tenant, "base", %{quantity: 2, occurred_at: ctx.at},
                 id: "fix"
               )

      assert c.id != r.id
      assert c.seq < r.seq
      assert {:ok, ^c} = Events.get(ctx.tenant, "fix")
      assert {:ok, ^r} = Events.get(ctx.tenant, "fix~r")
    end
  end
end
