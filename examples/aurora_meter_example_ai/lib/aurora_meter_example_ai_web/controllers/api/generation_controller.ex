defmodule AuroraMeterExampleAiWeb.Api.GenerationController do
  @moduledoc """
  The metered HTTP endpoint, and the other half of the plug's story.

  `AuroraMeter.Plug.EnsureEntitled` has already refused a caller whose plan does
  not allow images at all, which keeps that 403 out of every action. It has
  **not** reserved anything. This action still calls
  `AuroraMeterExampleAi.Generations.create/3`, which takes the quota through
  `AuroraMeter.with_quota/4`, and that is the only place a unit is actually
  claimed.

  So `{:error, :limit_exceeded}` below is not defensive programming. The plug
  said yes and the reservation said no, which under concurrency is exactly the
  window between them.
  """
  use AuroraMeterExampleAiWeb, :controller

  alias AuroraMeterExampleAi.Generations
  alias AuroraMeterExampleAiWeb.ApiAuth

  def create(conn, params) do
    scope = ApiAuth.scope(conn)
    request_id = params["request_id"] || Ecto.UUID.generate()

    attrs = %{
      "kind" => params["kind"] || "image",
      "prompt" => params["prompt"] || "",
      "model" => params["model"] || "nimbus-1-mini"
    }

    case Generations.create(scope, attrs, request_id) do
      {:ok, generation, outcome} ->
        conn
        |> put_status(if(outcome == :created, do: :created, else: :ok))
        |> json(%{
          id: generation.id,
          outcome: outcome,
          status: generation.status,
          prompt_tokens: generation.prompt_tokens,
          completion_tokens: generation.completion_tokens,
          cost_micros: generation.cost_micros,
          event_id: generation.event_id,
          # Read back from the plug, which assigned it on the way in. It is
          # exactly `AuroraMeter.quota(tenant, :images)` and it is a snapshot
          # from before the work ran.
          quota_at_admission: quota_payload(conn.assigns[:aurora_meter_quota])
        })

      {:error, :limit_exceeded} ->
        conn |> put_status(402) |> json(%{error: "limit_exceeded", checked: "with_quota"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: describe(reason)})
    end
  end

  defp quota_payload(nil), do: nil

  defp quota_payload(quota),
    do: %{kind: quota.kind, used: quota.used, limit: quota.limit, remaining: quota.remaining}

  defp describe({:provider_failed, message}), do: %{kind: "provider_failed", detail: message}
  defp describe({:conflict, existing}), do: %{kind: "conflict", detail: inspect(existing)}
  defp describe({:invalid, errors}), do: %{kind: "invalid", detail: inspect(errors)}
  defp describe({:unavailable, reason}), do: %{kind: "unavailable", detail: inspect(reason)}
  defp describe(reason) when is_atom(reason), do: %{kind: to_string(reason)}
end
