defmodule AuroraMeter.TestPlans do
  @moduledoc false
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :ai_generations, 50, :hard
    feature :api_access, false
    feature :seats, 1
  end

  plan :pro do
    price 2_000
    limit :ai_generations, 1_000, :hard
    feature :api_access, true
    feature :seats, 5
  end

  plan :scale do
    price 2_000
    metered :ai_generations, included: 1_000, unit_price: 2
    feature :api_access, true
    feature :seats, 25
  end
end
