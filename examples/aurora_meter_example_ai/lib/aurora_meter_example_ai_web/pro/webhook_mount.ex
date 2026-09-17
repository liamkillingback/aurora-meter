if Code.ensure_loaded?(AuroraMeter.Pro) do
  defmodule AuroraMeterExampleAiWeb.Pro.WebhookMount do
    @moduledoc """
    Mounts `AuroraMeter.Pro.Webhook` **before** `Plug.Parsers`, which is the
    only place it works.

    ## Why this is not a router `forward`

    Stripe signs the raw request body. `AuroraMeter.Pro.Webhook` recomputes the
    HMAC over the bytes it reads with `Plug.Conn.read_body/2`, and
    `Plug.Parsers` has already consumed those bytes by the time the router
    runs: `read_body/2` then answers `{:ok, "", conn}`, the computed signature
    is the signature of an empty string, and **every** event fails
    verification with a 400.

    Pro's own documentation shows `forward "/webhooks/stripe",
    AuroraMeter.Pro.Webhook` and says "mount it where the raw request body is
    still available (before `Plug.Parsers`, or with a cached raw body)". Both
    halves are true and only the second sentence is actionable, because a
    Phoenix router is always after the endpoint's parsers. This plug is the
    first of the two options, and it is nine lines.

    The failure it prevents is the worst shape a failure can have: it is
    silent, it is total, and its symptom appears at the other end of the
    system as customers who paid and were never credited. There is a test for
    it in `test/pro/webhook_test.exs` that mounts the plug the wrong way round
    and asserts the 400, so the warning in this moduledoc is a measured fact
    rather than folklore.
    """

    @behaviour Plug

    @path "/webhooks/stripe"

    @doc "The path this mount answers on."
    @spec path() :: String.t()
    def path, do: @path

    @impl Plug
    def init(opts), do: AuroraMeter.Pro.Webhook.init(opts)

    @impl Plug
    def call(%Plug.Conn{path_info: ["webhooks", "stripe"]} = conn, opts) do
      AuroraMeter.Pro.Webhook.call(conn, opts)
    end

    def call(conn, _opts), do: conn
  end
end
