defmodule AuroraMeter.Test.PooledTestRepo do
  @moduledoc """
  A repo pointed at `aurora_meter_test` with an ordinary pool and no sandbox.

  It exists for one test: `mix aurora_meter.bench` has two refusals in front of
  its end-to-end modes, the Ecto sandbox and a database whose name does not end
  in `_bench`, and the ordinary test repo trips the FIRST one, so the second
  could never be observed. This repo is the pooled half without the bench
  database, which is exactly the configuration the name guard exists for.

  It is never started: reading the configuration needs no connection, and the
  configuration is all the guard reads.
  """
  use Ecto.Repo, otp_app: :aurora_meter, adapter: Ecto.Adapters.Postgres
end
