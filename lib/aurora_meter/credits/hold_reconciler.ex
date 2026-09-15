defmodule AuroraMeter.Credits.HoldReconciler do
  @moduledoc """
  What a host says about a hold that is still open long after its work should
  have finished.

  A hold is taken before the row that remembers it exists, so a process killed
  in between leaves money reserved against a tenant with nothing left pointing
  at it. The ledger can list those holds (`AuroraMeter.Credits.pending_holds/1`)
  and it can close them, but it cannot tell one apart from a hold whose work is
  simply still running. Only the host knows that, and this behaviour is how it
  says so.

      defmodule MyApp.HoldPolicy do
        @behaviour AuroraMeter.Credits.HoldReconciler

        @impl true
        def decide(%{reference: "job:" <> id}) do
          case MyApp.Jobs.get(id) do
            %{state: :running} -> :keep
            %{state: :failed} -> :release
            %{state: :done, cost: cost} -> {:settle, cost}
            nil -> :release
          end
        end

        def decide(_hold), do: :keep
      end

      config :aurora_meter, credits_hold_reconciler: MyApp.HoldPolicy

  Configure it as the module above, as a `{module, function}` pair of arity 1,
  or as a one-argument function. `nil`, the default, keeps every hold.

  ## Age is not evidence

  The `:age_seconds` and `:held_at` fields say how long the hold has been open.
  They do **not** say the work is abandoned, and nothing in Aurora Meter will
  ever treat them that way. A job that legitimately runs for nine hours and a
  job whose process was killed nine hours ago are the same row. Deciding from
  the age alone releases money that is about to be spent, and the settle that
  follows takes the balance negative.

  There is a second reason not to lean on the age, and it is mechanical. A hold
  row's `inserted_at` is stamped by the node that took the hold, from a wall
  clock that is not monotonic and is not shared with the node running the
  reconciler. The age is therefore accurate to within whatever those two clocks
  disagree by. It is a hint for a log line and a metric, not a predicate.

  Decide from something that actually knows: the host's own job table, its
  queue, a heartbeat the worker writes.

  ## Rules for an implementation

  * `decide/1` may be called **more than once for one hold**. Two nodes running
    a sweep at the same time both list it and both ask. Make the callback
    side-effect free, or idempotent.
  * It runs **outside** any database transaction and while no ledger row lock is
    held, in a process of its own under `AuroraMeter.TaskSupervisor`.
  * It must return within `:credits_hold_reconciler_timeout` (default 5000 ms).
    Past that the process is killed with `:brutal_kill` and the hold is kept.
    Do not make a network call from it.
  * **Anything that is not a valid decision means `:keep`.** A raise, an exit, a
    throw, a timeout, a value that is not `:keep`, `:release` or
    `{:settle, non_neg_integer}`, or no configured reconciler at all: every one
    of them keeps the hold. There is no path on which a failure releases money.
  * A decision is advisory until it is applied. Between `decide/1` returning and
    the ledger applying it, the hold's own worker may have closed it; the
    application re-reads the status under the row lock and the run reports
    `:already_closed`.

  ## Dry runs

  `AuroraMeter.Credits.reconcile_holds(older_than: t, reconciler: fn _ -> :keep end)`
  examines and reports without moving anything, which is how to find out what a
  sweep would look at before configuring a policy that can release money.
  """

  @typedoc """
  One open hold, as it stood when the run listed it.

  `amount` is the reserved micro-USD, `held_at` the hold row's `inserted_at`,
  `age_seconds` the difference between the instant the run started and
  `held_at`, never negative, and `metadata` whatever the host passed to
  `AuroraMeter.Credits.hold/4`.
  """
  @type hold :: %{
          tenant_key: String.t(),
          reference: String.t(),
          amount: pos_integer(),
          held_at: DateTime.t(),
          age_seconds: non_neg_integer(),
          metadata: map()
        }

  @typedoc """
  Keep the reservation, hand it back, or charge `amount` micro-USD and close it.

  `{:settle, 0}` is a settle for nothing, which closes the hold and returns the
  whole reservation. It is not the same as `:release`: the ledger records a
  `:settle` entry rather than a `:release` one, so the log says the work
  finished and cost nothing rather than that it never finished.
  """
  @type decision :: :keep | :release | {:settle, non_neg_integer()}

  @doc """
  What to do with `hold`.

  Called once per hold per run, outside any transaction, in its own process.
  Anything other than a `t:decision/0` keeps the hold.
  """
  @callback decide(hold()) :: decision()
end
