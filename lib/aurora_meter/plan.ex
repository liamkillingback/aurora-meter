defmodule AuroraMeter.Plan do
  @moduledoc """
  A billing plan: an id, a monthly price (minor units / cents), and a map of
  feature configurations.

  Feature configs:

    * `{:limit, n, :hard}` — hard cap; blocks at `n`.
    * `{:metered, included, unit_price}` — allow overage; bill beyond `included`.
    * `{:feature, boolean}` — plain feature access (no quota).
  """

  @type feature_config ::
          {:limit, non_neg_integer(), :hard}
          | {:metered, non_neg_integer(), number()}
          | {:feature, boolean()}

  @type t :: %__MODULE__{
          id: atom(),
          price: non_neg_integer(),
          features: %{optional(atom()) => feature_config()}
        }

  defstruct id: nil, price: 0, features: %{}
end
