defmodule Demo do
  @moduledoc """
  A tiny end-to-end demo that installs Aurora Meter as a normal dependency and
  drives the whole flow. Run with `mix run -e "Demo.run()"`.
  """

  def run do
    org = "org_#{System.unique_integer([:positive])}"
    line()
    IO.puts("Aurora Meter demo — tenant #{org}")
    line()

    {:ok, _} = AuroraMeter.subscribe(org, :free)
    IO.puts("subscribed to plan: #{AuroraMeter.plan(org).id}")

    Enum.each(1..100, fn _ -> AuroraMeter.track(org, :api_calls) end)
    IO.puts("tracked 100 api_calls -> usage = #{AuroraMeter.usage(org, :api_calls)}")
    IO.puts("remaining = #{inspect(AuroraMeter.remaining(org, :api_calls))}")
    IO.puts("check(api_calls) at cap = #{inspect(AuroraMeter.check(org, :api_calls))}")
    IO.puts("with_quota at cap = #{inspect(AuroraMeter.with_quota(org, :api_calls, fn -> :ran end))}")
    IO.puts("entitled?(webhooks) on free = #{AuroraMeter.entitled?(org, :webhooks)}")

    line()
    {:ok, _} = AuroraMeter.subscribe(org, :pro)
    IO.puts("upgraded to plan: #{AuroraMeter.plan(org).id}")
    IO.puts("check(api_calls) after upgrade = #{inspect(AuroraMeter.check(org, :api_calls))}")
    IO.puts("remaining after upgrade = #{inspect(AuroraMeter.remaining(org, :api_calls))}")
    IO.puts("entitled?(webhooks) on pro = #{AuroraMeter.entitled?(org, :webhooks)}")

    line()
    {:ok, flushed} = AuroraMeter.Flusher.flush()
    IO.puts("flushed #{flushed} counter(s) to Postgres")
    IO.puts("usage after flush (from ETS+DB) = #{AuroraMeter.usage(org, :api_calls)}")
    IO.puts("billing checkout (no Pro installed) = #{inspect(AuroraMeter.Billing.checkout(org, :pro))}")
    line()
    IO.puts("DEMO OK")
  end

  defp line, do: IO.puts(String.duplicate("-", 60))
end
