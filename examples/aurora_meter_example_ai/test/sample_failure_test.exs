defmodule AuroraMeterExampleAi.SampleFailureTest do
  @moduledoc """
  L09d-3: every recipe's documented end state is asserted, so a recipe cannot
  drift from what the software does.

  One test per recipe, each asserting the exact figures `docs/failures.md`
  documents, plus two cross-checks over the document itself: that its headings
  and the implemented recipes are the same set in both directions, and that no
  recovery step in it edits a row.

  `async: false` and the whole file shares one journal: the reference exporter
  is a named `Agent` and two tests scripting it at once would see each other's
  outcomes.
  """
  use AuroraMeterExampleAi.DataCase, async: false
  use AuroraMeter.Test, reset: true

  alias AuroraMeter.Exporter.Journal
  alias AuroraMeterExampleAi.Failures

  @doc_path Path.expand("../docs/failures.md", __DIR__)

  setup do
    # The recipes spawn: `untrappable_death` runs the generation in a `Task`
    # and `reconcile_holds/1` asks the reconciler in a process of its own.
    # Shared mode is what lets those see the sandbox connection, and it is why
    # this file is not async.
    Ecto.Adapters.SQL.Sandbox.mode(AuroraMeterExampleAi.Repo, {:shared, self()})
    Journal.reset()
    :ok
  end

  describe "the document and the code are the same eight recipes" do
    test "L09d-3 every recipe in docs/failures.md has an implementation" do
      documented = documented_recipes()
      implemented = Failures.names()

      assert documented != [], "no recipe headings were found in docs/failures.md at all"

      assert Enum.sort(documented) == Enum.sort(implemented), """
      docs/failures.md documents: #{inspect(Enum.sort(documented))}
      AuroraMeterExampleAi.Failures implements: #{inspect(Enum.sort(implemented))}

      A recipe that is documented and not implemented is a paragraph. One that is
      implemented and not documented is a test nobody will find.
      """
    end

    test "L09d-3 the heading parser can see a heading, and is not matching every line" do
      # The control for the cross-check above. Without it, a parser that
      # returned [] would make the assertion above fail loudly (good) but one
      # that returned every line would make it fail confusingly, and one that
      # happened to return the right eight strings for the wrong reason would
      # pass.
      assert parse_headings("## insufficient_balance\ntext\n## callback_raise\n") ==
               ["insufficient_balance", "callback_raise"]

      assert parse_headings("### not a recipe\n# nor this\nplain text\n") == []

      assert parse_headings("## What this catalogue does not cover\n") == []
    end

    # -----------------------------------------------------------------------
    # L09d-4, and the narrowing this instrument needed
    # -----------------------------------------------------------------------
    #
    # The obvious version of this test greps the whole document for UPDATE,
    # INSERT and DELETE. It was written that way and it failed on line 26, which
    # is the sentence stating the rule: "**No recovery step edits a row.** Not
    # one `UPDATE`, not one `INSERT`, not one `DELETE`."
    #
    # That is the same shape as `no_payment_test.exs`'s amendment and it has the
    # same answer: **you cannot state the rule without the word.** What the
    # criterion is about is a recovery STEP, which is something a reader would
    # run, and a step is code. So the scan reads only fenced code blocks inside
    # `### Recovery` sections, which is exactly the set of things a reader
    # copies out of this document and executes, and the control below plants one
    # there to show the scan can still fire.
    test "L09d-4 no recovery step in docs/failures.md contains UPDATE, INSERT or DELETE" do
      steps = recovery_code(File.read!(@doc_path))

      assert steps != [],
             "no Recovery code blocks were found at all, so this scan is reading nothing"

      offenders = Enum.filter(steps, &Regex.match?(~r/\b(UPDATE|INSERT|DELETE)\b/, &1))

      assert offenders == [], """
      A recovery step in docs/failures.md edits a row:

      #{Enum.join(offenders, "\n")}

      Every recovery step is a named function or a Mix task. 04e removed the
      console mutation recipes from Aurora Meter Pro's own documentation for the
      same reason: a row edit records neither the decision nor what the person
      making it believed.
      """
    end

    test "L09d-4 the row-edit scan reads recovery code and can see a row edit in it" do
      # Three legs. The first shows the extractor finds code in a Recovery
      # section; the second shows it ignores prose in the same section, which
      # is the narrowing; the third shows it ignores code in a section that is
      # not Recovery, which is the other half of the narrowing.
      doc = """
      ## a_recipe

      ### Trigger

      ```sql
      DELETE FROM somewhere_else;
      ```

      ### Recovery

      Not by printing an UPDATE, which is prose about the rule.

      ```elixir
      MyApp.fix(id, expected: %{state: "uncertain"})
      ```

      ### What stays uncertain
      """

      code = recovery_code(doc)

      assert Enum.any?(code, &(&1 =~ "MyApp.fix"))
      refute Enum.any?(code, &(&1 =~ "prose about the rule"))
      refute Enum.any?(code, &(&1 =~ "somewhere_else"))
      assert Enum.filter(code, &Regex.match?(~r/\b(UPDATE|INSERT|DELETE)\b/, &1)) == []

      guilty =
        String.replace(
          doc,
          "MyApp.fix(id, expected: %{state: \"uncertain\"})",
          "UPDATE items SET state = 'accepted';"
        )

      assert Enum.filter(recovery_code(guilty), &Regex.match?(~r/\b(UPDATE|INSERT|DELETE)\b/, &1)) !=
               []
    end
  end

  describe "insufficient_balance" do
    test "I11 it leaves no hold, no event and no generation, and names two different refusals" do
      {:ok, report} = Failures.run("insufficient_balance", apply_recovery: false)

      assert report.application.empty_wallet_returns == "{:error, :insufficient_credits}"
      assert report.application.indebted_wallet_returns == "{:error, :debt_outstanding}"

      assert report.database.generations_rows == []
      assert report.database.sample_outbox_items == []

      assert report.ledger.unchanged
      assert report.ledger.after.held == 0
      assert report.ledger.after.conservation.holds

      # The indebted wallet is the half the recent repairs made reachable, and
      # every one of these four figures is one of their decisions.
      indebted = report.ledger.indebted
      assert indebted.debt > 0
      assert indebted.promotional > 0, "the promotion must survive the debt (R2)"
      assert indebted.spendable == 0, "spendable must read zero while the wallet owes (R3)"
      assert indebted.promotional_spendable == 0
      assert indebted.available > 0, "available is an identity and does not move (R3)"
      assert indebted.conservation.holds
    end
  end

  describe "callback_raise" do
    test "I03 it releases the hold and the reservation and records nothing" do
      {:ok, report} = Failures.run("callback_raise", apply_recovery: false)

      assert report.application.returns =~ "provider_failed"

      assert [%{status: "rejected", event_id: nil}] = report.database.generations_rows
      assert report.database.sample_outbox_items == []

      assert report.ledger.held_returned
      assert report.ledger.balance_unchanged
      assert report.ledger.after.held == 0
      assert report.ledger.usage_before == report.ledger.usage_after
      assert report.ledger.after.conservation.holds
    end
  end

  describe "untrappable_death" do
    test "I06 the event and its export intent survive the kill and the generations row does not" do
      {:ok, report} = Failures.run("untrappable_death", apply_recovery: false)

      assert report.application.process_exit_reason == ":killed"
      assert report.application.reached_the_seam, "the fault seam was never reached"

      assert report.database.sample_outbox_item_present
      refute report.database.generations_row_present
      assert report.database.orphans_reported_by_ops == 1

      # The half the first draft of this recipe got wrong.
      assert report.ledger.held_after_the_kill > 0,
             "the kill lands inside with_credits/4, so the hold must still be open"

      assert report.ledger.after_the_kill.available <
               report.ledger.before.available

      assert report.ledger.after_the_kill.conservation.holds

      # And the trap `pending_holds/1` sets for a host (X396).
      assert [hold] = report.database.pending_holds
      assert hold.held_delta > 0
      assert hold.amount_column == 0
    end

    test "I06 sample.repair rebuilds the row and reconcile_holds settles the hold once" do
      {:ok, report} = Failures.run("untrappable_death", apply_recovery: true)

      assert report.recovery.ran
      assert report.recovery.result.orphans == 1
      assert [%{rebuilt: true}] = report.recovery.result.rebuilt
      assert report.recovery.generations_row_after

      holds = report.recovery.holds
      assert holds.ran
      assert holds.examined == 1
      assert holds.settled == 1
      assert holds.released == 0
      assert holds.kept == 0

      # Settled for what it really cost, not for what was estimated.
      assert report.ledger.after_recovery.held == 0
      assert report.ledger.after_recovery.spent > 0

      assert report.ledger.after_recovery.spent <
               report.ledger.held_after_the_kill,
             "the settle must be the actual cost, which is below the estimate that was held"

      assert report.ledger.after_recovery.conservation.holds
    end
  end

  describe "worker_retry" do
    test "I16 it produces two attempts and one effect" do
      {:ok, report} = Failures.run("worker_retry", apply_recovery: false)

      assert report.effects.delivery_attempts == 2
      assert report.effects.accepted_deliveries == 1

      assert report.database.after_first_tick.state == "pending"
      assert report.database.after_first_tick.attempts == 1
      assert report.database.after_first_tick.last_outcome == "retry:1"

      assert report.database.after_second_tick.state == "delivered"
      assert report.database.after_second_tick.last_outcome == "accepted"

      # The documented surprise: the column counts retries, not attempts.
      assert report.database.after_second_tick.attempts == 1
    end
  end

  describe "duplicate_event" do
    test "I06 one identity produces one event, one projection delta and one intent" do
      {:ok, report} = Failures.run("duplicate_event", apply_recovery: false)

      assert report.application.first_call =~ ":inserted"
      assert report.application.second_call =~ ":duplicate"
      assert report.application.third_call_with_a_different_payload =~ ":conflict"

      assert report.database.sample_outbox_items_for_that_id == 1
      assert report.projection.delta == 40
      assert report.projection.usage_after - report.projection.usage_before == 40
    end
  end

  describe "exporter_timeout" do
    test "I15 it leaves an uncertain item that nothing retries, and names what stays unknown" do
      {:ok, report} = Failures.run("exporter_timeout", apply_recovery: false)

      assert report.database.after_first_tick.state == "uncertain"
      assert is_nil(report.database.after_first_tick.next_attempt_at)

      # The control is inside the recipe: an `:accepted` is queued behind the
      # `:uncertain`, so anything that retried would have moved the item to
      # `delivered` and this assertion would fail rather than quietly pass.
      assert report.database.after_three_more_ticks.state == "uncertain"
      assert report.database.never_retried

      assert report.database.horizon_seconds == 23 * 60 * 60
      assert report.database.within_horizon

      assert length(report.uncertain) == 4

      # The criterion is that this list MATCHES the programme's own statement
      # of what stays uncertain, so the first entry quotes it rather than
      # paraphrasing it, and this asserts the quotation is there.
      assert Enum.any?(
               report.uncertain,
               &(&1 =~ "financial-correctness-review.md section 8" and
                   &1 =~ "acceptance vs asynchronous rejection")
             )

      assert Enum.any?(report.uncertain, &(&1 =~ "empty search at the provider is NOT proof"))
      assert Enum.any?(report.uncertain, &(&1 =~ "23 hour horizon"))

      assert report.recovery.needed
      refute report.recovery.command =~ ~r/\b(UPDATE|INSERT|DELETE)\b/
    end
  end

  describe "late_correction" do
    test "I09 it produces an immutable correction, a bounded net quantity and its own intent" do
      {:ok, report} = Failures.run("late_correction", apply_recovery: false)

      assert report.application.correction =~ "kind: :correction"
      assert report.application.over_correction_refused =~ "exceeds_original"
      assert report.application.repeated_correction_id =~ ":duplicate"

      assert report.quantities.usage_now ==
               report.quantities.original - report.quantities.reduced_by

      assert report.quantities.bound_holds

      # The original is untouched and the correction is its own row.
      assert report.database.original_item.state == "delivered"
      assert report.database.original_item.quantity == report.quantities.original
      assert [correction] = report.database.correction_items
      assert correction.quantity == report.quantities.reduced_by
      assert correction.event_id != report.database.original_item.event_id

      assert length(report.uncertain) == 2
    end
  end

  describe "customer_cancellation" do
    test "I13 it is refused by name without the Pro profile, and runs with it" do
      if Code.ensure_loaded?(AuroraMeter.Pro) do
        {:ok, report} = Failures.run("customer_cancellation", apply_recovery: false)
        assert report.recipe == "customer_cancellation"
        assert report.profile == :pro
      else
        # The refusal is the assertion. A Pro-only recipe must abort by name
        # rather than degrade into a demonstration of something else, and this
        # is that promise made into a test rather than a sentence.
        assert_raise RuntimeError, ~r/needs the Pro profile/, fn ->
          Failures.run("customer_cancellation", apply_recovery: false)
        end
      end
    end
  end

  describe "the runner" do
    test "an unknown recipe is refused by name and lists the known ones" do
      assert {:error, {:unknown_recipe, "nope", known}} = Failures.run("nope")
      assert "insufficient_balance" in known
      assert length(known) == 8
    end
  end

  defp documented_recipes do
    @doc_path |> File.read!() |> parse_headings()
  end

  # Every line inside a fenced code block that is inside a `### Recovery`
  # section. A `###` heading of any other name ends the section; so does a `##`.
  defp recovery_code(text) do
    {lines, _state} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], %{in_recovery: false, in_fence: false}}, fn line, {acc, state} ->
        trimmed = String.trim(line)

        cond do
          String.starts_with?(trimmed, "```") and state.in_recovery ->
            {acc, %{state | in_fence: not state.in_fence}}

          state.in_fence and state.in_recovery ->
            {[line | acc], state}

          trimmed == "### Recovery" ->
            {acc, %{state | in_recovery: true, in_fence: false}}

          String.starts_with?(trimmed, "### ") or String.starts_with?(trimmed, "## ") ->
            {acc, %{state | in_recovery: false, in_fence: false}}

          true ->
            {acc, state}
        end
      end)

    Enum.reverse(lines)
  end

  # A recipe heading is `## <name>` where `<name>` is a lower-case identifier.
  # The document's other `##` headings are English sentences and are skipped by
  # the shape rather than by a list of exceptions, which is why "What this
  # catalogue does not cover" needs no special case.
  defp parse_headings(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^## ([a-z][a-z0-9_]*)$/, String.trim_trailing(line)) do
        [_, name] -> [name]
        nil -> []
      end
    end)
  end
end
