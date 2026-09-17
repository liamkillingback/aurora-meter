defmodule AuroraMeterExampleAi.HoldPolicy do
  @moduledoc """
  What this application says about a credit hold that is still open long after
  its work should have finished.

  ## Why a host has to answer this at all

  A hold is taken before the row that remembers it exists, and the two are
  different databases as often as not, so there is no way to make them one
  write. A process killed in between leaves money reserved against a tenant
  with nothing left pointing at it. The ledger can list those holds and it can
  close them; it cannot tell one apart from a hold whose work is still running,
  because that is a fact about **this** application and not about the ledger.

  `docs/failures.md`'s `untrappable_death` recipe is where this is not
  hypothetical. A process killed after `AuroraMeter.record/4` committed and
  before `AuroraMeterExampleAi.Generations` wrote its own row leaves:

    * the durable event, its projection delta and its export intent: committed;
    * this application's `generations` row: missing;
    * **the credit hold: open**, because the settle is what the callback would
      have returned and the callback never returned.

  The money is therefore not wrong, it is *pending*, and it stays pending until
  somebody decides. This module is that decision.

  ## What it decides from, and what it refuses to decide from

  It decides from the **export intent**, which is this application's own record
  of what was recorded, staged inside the transaction that wrote the event. If
  the intent is there, the work finished and its real cost is computable from
  the quantity, so the hold is settled for that cost and the difference goes
  back. If it is not there, nothing was ever recorded, so the hold is released
  whole.

  It does **not** decide from `age_seconds`. The library's own documentation is
  blunt about why and it is worth repeating: a job that legitimately runs for
  nine hours and a job whose process was killed nine hours ago are the same
  row, and the age is stamped by a clock on a different node. Age makes a hold
  a candidate to be **asked** about, never a candidate to be released.

  ## Running a sweep

  Nothing in this sample runs one on a schedule, deliberately: a sample that
  quietly released money on a timer would be teaching the wrong reflex. A real
  application runs

      AuroraMeter.Credits.reconcile_holds(
        older_than: DateTime.add(AuroraMeter.Clock.now(), -3600, :second)
      )

  from its scheduler, after a dry run:

      AuroraMeter.Credits.reconcile_holds(
        older_than: ..., reconciler: fn _hold -> :keep end
      )

  which reports what a sweep would look at and writes nothing.
  """
  @behaviour AuroraMeter.Credits.HoldReconciler

  alias AuroraMeterExampleAi.Repo
  alias AuroraMeterExampleAi.SampleOutbox.Item
  alias AuroraMeterExampleAi.Tokens

  @impl AuroraMeter.Credits.HoldReconciler
  @spec decide(AuroraMeter.Credits.HoldReconciler.hold()) ::
          :keep | :release | {:settle, non_neg_integer()}
  def decide(%{reference: "gen:" <> _ = reference, tenant_key: tenant_key}) do
    case Repo.get_by(Item, tenant_key: tenant_key, event_id: reference) do
      # The export intent exists, so `record/4` committed: the work happened
      # and its cost is the quantity that was recorded. Settling for the real
      # cost rather than for the estimate is the whole point of a hold.
      %Item{quantity: quantity, state: state} when state != "skipped" ->
        {:settle, Tokens.cost_micros(0, quantity)}

      # Nothing was ever recorded under this reference. The customer owes
      # nothing and the reservation goes back whole.
      _nothing ->
        :release
    end
  rescue
    # Anything that is not a valid decision keeps the hold, and the library
    # treats a raise as exactly that. Rescuing here and returning `:keep`
    # explicitly is the same outcome said out loud.
    _error -> :keep
  end

  # A hold this application did not take. Not ours to decide.
  def decide(_hold), do: :keep
end
