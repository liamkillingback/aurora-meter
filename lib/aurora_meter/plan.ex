defmodule AuroraMeter.Plan do
  @moduledoc """
  A billing plan: an id, a monthly price (minor units / cents), a map of
  feature configurations and any recurring credit allowances it grants.

  Feature configs:

    * `{:limit, n, :hard}`: hard cap; blocks at `n`.
    * `{:metered, included, unit_price}`: allow overage; bill beyond `included`.
    * `{:counter}`: measured, never blocked, never billed; no denominator.
    * `{:feature, boolean}`: plain feature access (no quota).
    * `{:feature, non_neg_integer}`: a plan-level value with no counter behind
      it (seats, retention days, projects): always entitled; read it with
      `AuroraMeter.feature_value/3`.

  `recurring_credits` is a list of allowance declarations in declaration order,
  each a map of `name`, `amount`, `category`, `rollover` and `expires`. It is
  empty unless the plan declares `AuroraMeter.Plans.recurring_credits/2`, which
  is what makes recurring grants off by default. `AuroraMeter.Credits.Recurrences`
  is the engine that reads it; a new declaration kind was added here rather than
  a new feature kind so every `feature_config/0` consumer is untouched.

  ## Identity

  A plan is identified by `{id, version}`, not by `id` alone. `version` is a
  short opaque string the host chooses (`"1"` when a block declares none),
  `effective_at` is the UTC instant from which that version is the one a new
  subscription gets (`nil` means "from the beginning"), and `fingerprint` is the
  sha256 of the version's commercial content. Two deploys of the same
  `{id, version}` with different content raise
  `AuroraMeter.PlanVersionConflictError` rather than repricing every tenant:
  see [Plans](plans.md).
  """

  @type feature_config ::
          {:limit, non_neg_integer(), :hard}
          | {:metered, non_neg_integer(), number()}
          | {:counter}
          | {:feature, boolean() | non_neg_integer()}

  @typedoc """
  One recurring allowance, as `AuroraMeter.Plans.recurring_credits/2` declares it.

  `expires` is `:period_end` (the lot expires when the period it was granted for
  ends), `:never`, or `{:seconds, n}` counted from the grant.
  """
  @type recurring_credit :: %{
          name: atom(),
          amount: pos_integer(),
          category: :promotional | :paid | :adjustment,
          rollover: non_neg_integer(),
          expires: :period_end | :never | {:seconds, pos_integer()}
        }

  @type t :: %__MODULE__{
          id: atom(),
          version: String.t(),
          price: non_neg_integer(),
          features: %{optional(atom()) => feature_config()},
          recurring_credits: [recurring_credit()],
          effective_at: DateTime.t() | nil,
          fingerprint: binary() | nil
        }

  @doc """
  The version every plan block carries when it does not declare one.

  It is the version `AuroraMeter.Plans.register!/0` backfills onto every
  subscription written before plan versions existed, so a tenant's commercial
  contract is named rather than implied (D05).
  """
  @spec base_version() :: String.t()
  def base_version, do: "1"

  defstruct id: nil,
            version: "1",
            price: 0,
            features: %{},
            recurring_credits: [],
            effective_at: nil,
            fingerprint: nil
end
