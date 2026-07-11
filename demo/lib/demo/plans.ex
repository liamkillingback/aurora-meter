defmodule Demo.Plans do
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :api_calls, 100, :hard
    feature :webhooks, false
  end

  plan :pro do
    price 2_900
    limit :api_calls, 10_000, :hard
    feature :webhooks, true
  end
end
