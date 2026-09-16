defmodule AuroraMeterExampleAi.SampleOutboxTest do
  @moduledoc """
  The host-owned outbox: staged inside the record transaction, drained outside
  it, and one documented state per exporter outcome.
  """
  use AuroraMeterExampleAi.DataCase, async: false
  use AuroraMeter.Test, reset: true

  alias AuroraMeter.Exporter.Journal
  alias AuroraMeterExampleAi.Generations
  alias AuroraMeterExampleAi.SampleFixtures
  alias AuroraMeterExampleAi.SampleOutbox.Drainer
  alias AuroraMeterExampleAi.SampleOutbox.Item

  @text %{"kind" => "text", "prompt" => "a poem about a ledger", "model" => "nimbus-1-mini"}

  setup do
    Journal.reset()
    :ok
  end

  defp generate(scope) do
    id = Ecto.UUID.generate()
    {:ok, generation, :created} = Generations.create(scope, @text, id)
    {generation, Generations.reference(id)}
  end

  describe "staging" do
    test "the intent is written in the same transaction as the event" do
      scope = SampleFixtures.funded_scope_fixture()
      {generation, reference} = generate(scope)

      assert [item] = Repo.all(Item)
      assert item.event_id == reference
      assert item.event_id == generation.event_id
      assert item.feature == "tokens"
      assert item.state == "pending"
      assert item.quantity == generation.prompt_tokens + generation.completion_tokens
      assert item.payload["identifier"] == reference
      assert item.payload["plan_id"] == "studio"
    end

    test "an outbox that refuses rolls the event back with it, and nothing is charged" do
      # The seam's contract in one test: an implementation that raises rolls the
      # caller's `record/4` back, and the caller sees `:unavailable`. It is
      # proved by pointing the configuration at a module that always raises,
      # and put back afterwards by an on_exit rather than by remembering.
      scope = SampleFixtures.funded_scope_fixture()
      original = Application.get_env(:aurora_meter, :events_outbox)
      on_exit(fn -> put_outbox(original) end)
      put_outbox(AuroraMeterExampleAi.SampleOutboxTest.Exploding)

      before = AuroraMeter.Credits.summary(scope.org)

      assert {:error, {:unavailable, {:outbox, _}}} =
               Generations.create(scope, @text, Ecto.UUID.generate())

      assert Repo.aggregate(Item, :count) == 0
      assert AuroraMeter.Credits.summary(scope.org).available == before.available
      assert AuroraMeter.Credits.summary(scope.org).held == 0
    end

    test "with the real outbox back, the same call succeeds" do
      # Discrimination for the test above: if the configuration swap had not
      # taken effect, that test would have passed for the wrong reason.
      scope = SampleFixtures.funded_scope_fixture()
      assert {:ok, _, :created} = Generations.create(scope, @text, Ecto.UUID.generate())
      assert Repo.aggregate(Item, :count) == 1
    end
  end

  describe "draining" do
    setup do
      scope = SampleFixtures.funded_scope_fixture(%{credit: 50_000_000})
      {_generation, reference} = generate(scope)
      %{scope: scope, reference: reference}
    end

    test "accepted becomes delivered", %{reference: reference} do
      Journal.script(reference, :accepted)
      assert %{claimed: 1} = Drainer.drain_now()
      assert %Item{state: "delivered", last_outcome: "accepted", attempts: 0} = Repo.one(Item)
    end

    test "accepted with a reference stores the reference", %{reference: reference} do
      Journal.script(reference, {:accepted, "prov_123"})
      Drainer.drain_now()
      assert %Item{state: "delivered", provider_ref: "prov_123"} = Repo.one(Item)
    end

    test "retry goes back to pending with an attempt and a next attempt time", %{
      reference: reference
    } do
      Journal.script(reference, {:retry, 30})
      Drainer.drain_now()

      item = Repo.one(Item)
      assert item.state == "pending"
      assert item.attempts == 1
      assert item.last_outcome == "retry:30"
      assert DateTime.compare(item.next_attempt_at, DateTime.utc_now()) == :gt
    end

    test "a retried item is not claimed again until its time comes", %{reference: reference} do
      Journal.script(reference, [{:retry, 30}, :accepted])
      assert %{claimed: 1} = Drainer.drain_now()
      assert %{claimed: 0} = Drainer.drain_now()

      # Move its clock back rather than waiting thirty seconds.
      Repo.update_all(Item, set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)])

      assert %{claimed: 1} = Drainer.drain_now()
      assert %Item{state: "delivered"} = Repo.one(Item)
    end

    test "uncertain stops, and is never retried automatically", %{reference: reference} do
      Journal.script(reference, [:uncertain, :accepted])
      Drainer.drain_now()
      assert %Item{state: "uncertain", last_outcome: "uncertain"} = Repo.one(Item)

      assert %{claimed: 0} = Drainer.drain_now()
      assert %Item{state: "uncertain"} = Repo.one(Item)
    end

    test "rejected stores the reason and stops", %{reference: reference} do
      Journal.script(reference, {:rejected, :no_such_customer})
      Drainer.drain_now()
      assert %Item{state: "rejected", last_outcome: "rejected:no_such_customer"} = Repo.one(Item)
      assert %{claimed: 0} = Drainer.drain_now()
    end

    test "an answer the exporter never gave is read as uncertain", %{reference: reference} do
      # `AuroraMeter.Exporter.normalize/2` reads a missing entry as `:uncertain`,
      # which is the most expensive state a caller can be left in and the only
      # honest one. Scripting a nonsense term is how the journal reaches it.
      Journal.script(reference, {:something, :nobody, :planned, :for})
      Drainer.drain_now()
      assert %Item{state: "uncertain"} = Repo.one(Item)
    end

    test "a claimed row whose drainer died is reclaimed after the reclaim window" do
      Repo.update_all(Item, set: [state: "claimed", updated_at: DateTime.utc_now()])
      assert %{claimed: 0} = Drainer.drain_now(), "a fresh claim must not be stolen"

      Repo.update_all(Item,
        set: [state: "claimed", updated_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert %{claimed: 1} = Drainer.drain_now()
      assert %Item{state: "delivered"} = Repo.one(Item)
    end
  end

  describe "eligibility" do
    test "an ineligible entry is recorded as skipped with its reason and never delivered" do
      # Core decides eligibility and this callback records what it was told.
      # Calling it directly is the only way to reach the ineligible branch
      # without a plan-attribution failure, and it is the branch a host is most
      # likely to get wrong.
      scope = SampleFixtures.funded_scope_fixture()
      key = AuroraMeterExampleAi.Tenancy.to_key(scope.org)

      event = %AuroraMeter.Event{
        id: Ecto.UUID.generate(),
        event_id: "probe:" <> Ecto.UUID.generate(),
        tenant_key: key,
        feature: :tokens,
        quantity: 7,
        kind: :usage,
        occurred_at: DateTime.utc_now(),
        recorded_at: DateTime.utc_now(),
        period_start: DateTime.utc_now() |> DateTime.truncate(:second),
        dimensions: %{},
        metadata: %{}
      }

      assert :ok =
               AuroraMeterExampleAi.SampleOutbox.enqueue(
                 [%{event: event, eligibility: {:ineligible, :plan_unresolved}}],
                 %{repo: Repo, timeout: 15_000}
               )

      assert %Item{state: "skipped", last_outcome: "ineligible:plan_unresolved"} =
               Repo.get_by(Item, event_id: event.event_id)

      assert %{claimed: 0} = Drainer.drain_now(), "a skipped item must never be delivered"
    end
  end

  # `AuroraMeter.Config` reads this key straight from the application
  # environment on every call, so a plain `put_env/3` takes effect immediately.
  # It changes the whole node, which is why every test in this module is
  # `async: false` and why the restore is registered before the change is made.
  defp put_outbox(module), do: Application.put_env(:aurora_meter, :events_outbox, module)

  defmodule Exploding do
    @moduledoc false
    @behaviour AuroraMeter.Events.Outbox

    @impl AuroraMeter.Events.Outbox
    def enqueue(_items, _context), do: raise("the outbox is down")
  end
end
