defmodule AuroraMeterExampleAiWeb.ApiErrors do
  @moduledoc """
  Renders `AuroraMeter.Plug.EnsureEntitled`'s refusals as JSON.

  The plug picks no content type and writes no body by default, because it does
  not know what a host's clients read. This is that decision, taken once.

  `:limit_exceeded` is mapped to 402 and `:not_entitled` to 403. The library
  defaults both to 403 and passes the reason through precisely so that a host
  can split them: the first means "this plan has run out this period" and the
  second means "this plan never had it". Neither is 429: an entitlement outcome
  for the current period is not a rate limit that clears in seconds, and a
  `Retry-After` header would be a lie.
  """

  import Plug.Conn

  @doc """
  Refuses the request. **Must** return a halted conn: an unhalted one raises,
  because a request that was refused and then served anyway is the one failure
  nothing else would notice.
  """
  @spec denied(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def denied(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_for(reason), Jason.encode!(%{error: reason, advisory: true}))
    |> halt()
  end

  defp status_for(:limit_exceeded), do: 402
  defp status_for(:not_entitled), do: 403
  defp status_for(:missing_tenant), do: 401
  defp status_for(:unavailable), do: 503
  defp status_for(_other), do: 403
end
