defmodule AuroraMeter.Plan do
  @moduledoc """
  A billing plan: an id, a monthly price (minor units / cents), and a map of
  feature configurations.

  Feature configs:

    * `{:limit, n, :hard}` — hard cap; blocks at `n`.
    * `{:metered, included, unit_price}` — allow overage; bill beyond `included`.
    * `{:counter}` — measured, never blocked, never billed; no denominator.
    * `{:feature, boolean}` — plain feature access (no quota).
    * `{:feature, non_neg_integer}` — a plan-level value with no counter behind
      it (seats, retention days, projects): always entitled; read it with
      `AuroraMeter.feature_value/3`.
  """

  @type feature_config ::
          {:limit, non_neg_integer(), :hard}
          | {:metered, non_neg_integer(), number()}
          | {:counter}
          | {:feature, boolean() | non_neg_integer()}

  @type t :: %__MODULE__{
          id: atom(),
          price: non_neg_integer(),
          features: %{optional(atom()) => feature_config()}
        }

  defstruct id: nil, price: 0, features: %{}
end
