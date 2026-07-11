defmodule AuroraMeter.TestRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :aurora_meter, adapter: Ecto.Adapters.Postgres
end
