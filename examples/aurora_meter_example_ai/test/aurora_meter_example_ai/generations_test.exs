defmodule AuroraMeterExampleAi.GenerationsTest do
  @moduledoc """
  The generation path, which is where the money is.

  Every test here is `async: false` and resets Aurora Meter's ETS tables first.
  The counters are global to the node, so a suite that shared them across
  concurrent tests would be measuring whichever test ran last.
  """
  use AuroraMeterExampleAi.DataCase, async: false
  use AuroraMeter.Test, reset: true

  alias AuroraMeter.Credits
  alias AuroraMeterExampleAi.Generations
  alias AuroraMeterExampleAi.Generations.Generation
  alias AuroraMeterExampleAi.SampleFixtures
  alias AuroraMeterExampleAi.SampleOutbox
  alias AuroraMeterExampleAi.Tokens

  @text %{"kind" => "text", "prompt" => "a poem about a ledger", "model" => "nimbus-1-mini"}
  @image %{"kind" => "image", "prompt" => "a picture of a ledger", "model" => "nimbus-1-mini"}

  defp text(overrides), do: Map.merge(@text, overrides)
  defp image(overrides), do: Map.merge(@image, overrides)

  describe "I11 hold, work, settle" do
    test "a settled generation reduces available by the ACTUAL cost, not the estimate" do
      scope = SampleFixtures.funded_scope_fixture()
      before = Credits.summary(scope.org)

      assert {:ok, generation, :created} =
               Generations.create(scope, @text, Ecto.UUID.generate())

      actual = Tokens.cost_micros(generation.prompt_tokens, generation.completion_tokens)

      assert generation.cost_micros == actual

      assert generation.estimate_micros > actual,
             "the estimate must exceed the actual, or this proves nothing"

      after_ = Credits.summary(scope.org)
      assert after_.available == before.available - actual
      assert after_.held == 0
    end

    test "the ledger shows one hold and one settlement, not two debits" do
      scope = SampleFixtures.funded_scope_fixture()
      id = Ecto.UUID.generate()
      {:ok, generation, :created} = Generations.create(scope, @text, id)

      kinds =
        scope.org
        |> Credits.history(kinds: AuroraMeter.Schema.CreditTransaction.kinds(), limit: 50)
        |> Enum.filter(&(&1.reference == Generations.reference(id)))
        |> Enum.map(& &1.kind)
        |> Enum.sort()

      assert kinds == [:hold, :settle]

      settle =
        scope.org
        |> Credits.history(kinds: [:settle], limit: 50)
        |> Enum.find(&(&1.reference == Generations.reference(id)))

      assert settle.amount == -generation.cost_micros
    end

    test "a generation whose work raises leaves the balance and the quota exactly as they were" do
      scope = SampleFixtures.funded_scope_fixture()
      before = Credits.summary(scope.org)
      images_before = AuroraMeter.usage(scope.org, :images)

      assert {:error, {:provider_failed, _}} =
               Generations.create(
                 scope,
                 image(%{"prompt" => "fail: on purpose"}),
                 Ecto.UUID.generate()
               )

      after_ = Credits.summary(scope.org)
      assert after_.available == before.available
      assert after_.held == 0
      assert AuroraMeter.usage(scope.org, :images) == images_before
      assert Repo.aggregate(from(g in Generation, where: g.status == "settled"), :count) == 0
    end

    test "a failed generation is visible in the history as rejected, and costs nothing" do
      scope = SampleFixtures.funded_scope_fixture()

      {:error, _} =
        Generations.create(scope, text(%{"prompt" => "fail: visibly"}), Ecto.UUID.generate())

      assert [%Generation{status: "rejected", cost_micros: nil}] = Generations.list(scope)
    end
  end

  describe "I06 and I07 one identity, one fact" do
    test "a second submit of one request id runs nothing and charges nothing" do
      scope = SampleFixtures.funded_scope_fixture()
      id = Ecto.UUID.generate()

      assert {:ok, first, :created} = Generations.create(scope, @text, id)
      after_first = Credits.summary(scope.org)

      assert {:ok, second, :duplicate} = Generations.create(scope, @text, id)

      assert second.id == first.id
      assert Credits.summary(scope.org).available == after_first.available
      assert Repo.aggregate(Generation, :count) == 1
    end

    test "twelve concurrent submits of one request id on independent connections produce one of everything" do
      # The pattern comes from the library's own concurrency tests: check out
      # non-sandbox connections so the twelve tasks really do race in the
      # database rather than queueing behind one owner.
      scope = SampleFixtures.funded_scope_fixture(%{credit: 50_000_000})
      id = Ecto.UUID.generate()
      reference = Generations.reference(id)

      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      results =
        1..12
        |> Task.async_stream(
          fn _ -> Generations.create(scope, @text, id) end,
          max_concurrency: 12,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # Every caller gets a coherent answer naming the same generation. Which
      # one of the twelve returns `:created` is a race and is not asserted:
      # the winner of the credit hold does the work, and a caller recovering
      # from this application's own outbox row can reach the `generations`
      # insert before it does. What must be true is that there is one of
      # everything and that nobody was told something false.
      assert Enum.all?(
               results,
               &match?(
                 {:ok, _generation, outcome} when outcome in [:created, :duplicate, :recovered],
                 &1
               )
             ),
             "some caller got an answer it cannot act on: #{inspect(results -- Enum.filter(results, &match?({:ok, _, _}, &1)))}"

      ids = results |> Enum.map(fn {:ok, generation, _} -> generation.id end) |> Enum.uniq()
      assert ids == [id], "callers were shown different generations: #{inspect(ids)}"

      assert length(results) == 12
      assert Repo.aggregate(Generation, :count) == 1

      holds =
        scope.org
        |> Credits.history(kinds: [:hold], limit: 50)
        |> Enum.count(&(&1.reference == reference))

      settles =
        scope.org
        |> Credits.history(kinds: [:settle], limit: 50)
        |> Enum.count(&(&1.reference == reference))

      assert holds == 1
      assert settles == 1

      assert Repo.aggregate(from(i in SampleOutbox.Item, where: i.event_id == ^reference), :count) ==
               1
    end

    test "I07 one request id reused for a different prompt is a conflict, and records nothing new" do
      scope = SampleFixtures.funded_scope_fixture()
      id = Ecto.UUID.generate()
      {:ok, original, :created} = Generations.create(scope, @text, id)
      events_before = Repo.aggregate(SampleOutbox.Item, :count)

      assert {:error, {:conflict, existing}} =
               Generations.create(scope, text(%{"prompt" => "a completely different prompt"}), id)

      assert existing.event_id == Generations.reference(id)
      assert existing.prompt == original.prompt
      assert Repo.aggregate(SampleOutbox.Item, :count) == events_before
      assert Repo.aggregate(Generation, :count) == 1
    end

    test "I06 an orphaned event resubmitted rebuilds the row from this application's own outbox row" do
      scope = SampleFixtures.funded_scope_fixture()
      id = Ecto.UUID.generate()
      {:ok, original, :created} = Generations.create(scope, @text, id)

      # The orphan: the durable event and the outbox intent committed, and this
      # application's own row did not. Deleting it is exactly the state a
      # process killed between the two transactions leaves behind.
      Repo.delete_all(Generation)
      after_first = Credits.summary(scope.org)

      assert {:ok, rebuilt, :recovered} = Generations.create(scope, @text, id)

      assert rebuilt.id == original.id
      assert rebuilt.event_id == original.event_id
      assert rebuilt.cost_micros == original.cost_micros
      assert Credits.summary(scope.org).available == after_first.available
      assert Repo.aggregate(SampleOutbox.Item, :count) == 1
    end

    test "with no outbox row and no local row, the identity is simply spent" do
      # Discrimination for the test above: the recovery must be reading the
      # outbox row rather than inventing a plausible one.
      scope = SampleFixtures.funded_scope_fixture()
      id = Ecto.UUID.generate()
      {:ok, _original, :created} = Generations.create(scope, @text, id)
      Repo.delete_all(Generation)
      Repo.delete_all(SampleOutbox.Item)

      assert {:error, :already_failed} = Generations.create(scope, @text, id)
    end

    test "a request id whose first attempt failed is spent, and says so" do
      scope = SampleFixtures.funded_scope_fixture()
      id = Ecto.UUID.generate()

      {:error, {:provider_failed, _}} =
        Generations.create(scope, text(%{"prompt" => "fail: once"}), id)

      assert {:error, :already_failed} = Generations.create(scope, @text, id)
    end
  end

  describe "I03 and I04 quota" do
    test "a free organisation's sixth image is refused before any work runs" do
      org = SampleFixtures.org_fixture(%{plan: :free})
      scope = SampleFixtures.scope_fixture(org)
      {:ok, _} = Credits.grant(org, 50_000_000, reference: SampleFixtures.grant_reference())

      for _ <- 1..5 do
        assert {:ok, _, :created} = Generations.create(scope, @image, Ecto.UUID.generate())
      end

      assert AuroraMeter.usage(org, :images) == 5
      before = Credits.summary(org)

      assert {:error, :limit_exceeded} =
               Generations.create(scope, @image, Ecto.UUID.generate())

      assert AuroraMeter.usage(org, :images) == 5, "a refused request must not consume a slot"
      assert Credits.summary(org).available == before.available
      assert Credits.summary(org).held == 0
    end

    test "a refusal for want of credit does NOT consume an image slot" do
      # This is the one that catches the mistake `with_quota/4` invites: an
      # error tuple returned from inside the callback commits the reservation.
      # The path raises instead, and this test is what says so.
      org = SampleFixtures.org_fixture(%{plan: :free})
      scope = SampleFixtures.scope_fixture(org)

      assert {:error, :insufficient_credits} =
               Generations.create(scope, @image, Ecto.UUID.generate())

      assert AuroraMeter.usage(org, :images) == 0
    end

    test "a text generation is gated by credit alone and takes no image slot" do
      org = SampleFixtures.org_fixture(%{plan: :free})
      scope = SampleFixtures.scope_fixture(org)
      {:ok, _} = Credits.grant(org, 50_000_000, reference: SampleFixtures.grant_reference())

      for _ <- 1..8 do
        assert {:ok, _, :created} = Generations.create(scope, @text, Ecto.UUID.generate())
      end

      assert AuroraMeter.usage(org, :images) == 0
    end
  end

  describe "I08 one input source, one commercial effect" do
    test "tokens never appears in a flush batch and images always does" do
      scope = SampleFixtures.funded_scope_fixture()
      key = AuroraMeterExampleAi.Tenancy.to_key(scope.org)
      {:ok, _, :created} = Generations.create(scope, @image, Ecto.UUID.generate())

      features =
        case AuroraMeter.Store.snapshot_flush_batch() do
          nil ->
            []

          %{counters: counters} ->
            counters |> Enum.filter(&(&1.tenant_key == key)) |> Enum.map(& &1.feature)
        end

      # The positive half first. Without it a batch that was empty for any
      # reason at all would pass the negative half, which is the shape this
      # programme keeps paying for.
      assert :images in features,
             "the buffered feature was absent from the flush batch, so the negative below proves nothing: #{inspect(features)}"

      refute :tokens in features
    end

    test "AuroraMeter.track/4 raises for an events-source feature" do
      scope = SampleFixtures.funded_scope_fixture()
      assert_raise ArgumentError, fn -> AuroraMeter.track(scope.org, :tokens) end
    end

    test "images never reaches the outbox and tokens always does" do
      scope = SampleFixtures.funded_scope_fixture()
      {:ok, _, :created} = Generations.create(scope, @image, Ecto.UUID.generate())

      features =
        SampleOutbox.Item |> Repo.all() |> Enum.map(& &1.feature) |> Enum.uniq()

      assert features == ["tokens"]
    end
  end

  describe "D07 credit priority" do
    test "spend draws the earlier-expiring promotional lot, then the later one, then the paid lot" do
      org = SampleFixtures.org_fixture()
      scope = SampleFixtures.scope_fixture(org)
      now = DateTime.utc_now()

      # Two very small promotional lots, so that one generation costs more than
      # both together and has to reach the paid one. If they were large the
      # spend would stop inside the first lot and the order after it would be
      # unobserved, which is a test that passes without seeing what it claims.
      {:ok, _} =
        Credits.grant(org, 60,
          reference: SampleFixtures.grant_reference("early"),
          category: :promotional,
          expires_at: now |> DateTime.add(7, :day) |> DateTime.truncate(:second)
        )

      {:ok, _} =
        Credits.grant(org, 60,
          reference: SampleFixtures.grant_reference("late"),
          category: :promotional,
          expires_at: now |> DateTime.add(60, :day) |> DateTime.truncate(:second)
        )

      {:ok, _} =
        Credits.grant(org, 10_000_000,
          reference: SampleFixtures.grant_reference("paid"),
          category: :paid
        )

      lots = Credits.Lots.list(org, states: :all)

      assert length(lots) == 3,
             "the lot engine is off for this wallet, so this test proves nothing"

      # One generation costs more than the two promotional lots together, so it
      # has to reach the paid one, which is what makes the order visible.
      {:ok, generation, :created} = Generations.create(scope, @text, Ecto.UUID.generate())

      assert generation.cost_micros > 120,
             "the spend did not exceed the two promotional lots, so the order after them is unobserved"

      order =
        org
        |> Credits.Lots.allocations(limit: 50)
        |> Enum.filter(&(&1.kind in [:reserve, :consume]))
        |> Enum.map(& &1.lot_id)
        |> Enum.uniq()

      by_id = Map.new(Credits.Lots.list(org, states: :all), &{&1.id, &1})
      categories = Enum.map(order, &by_id[&1].category)
      expiries = Enum.map(order, &by_id[&1].expires_at)

      assert categories == [:promotional, :promotional, :paid],
             "drawn in the wrong order: #{inspect(categories)}"

      [early, late, _paid] = expiries
      assert DateTime.compare(early, late) == :lt
    end
  end

  describe "validation" do
    test "an unknown model, an empty prompt and a non-uuid request id are all refused by name" do
      scope = SampleFixtures.funded_scope_fixture()

      assert {:error, {:invalid, errors}} =
               Generations.create(
                 scope,
                 %{"kind" => "text", "prompt" => "", "model" => "nope"},
                 "not-a-uuid"
               )

      assert {:prompt, :required} in errors
      assert {:model, :unknown} in errors
      assert {:request_id, :must_be_a_uuid} in errors
    end

    test "nothing at all is written for an invalid request" do
      scope = SampleFixtures.funded_scope_fixture()
      before = Credits.summary(scope.org)

      {:error, {:invalid, _}} =
        Generations.create(scope, %{"kind" => "text", "prompt" => "", "model" => "nope"}, "x")

      assert Repo.aggregate(Generation, :count) == 0
      assert Repo.aggregate(SampleOutbox.Item, :count) == 0
      assert Credits.summary(scope.org) == before
    end
  end
end
