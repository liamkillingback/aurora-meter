# Rules for working with Aurora Meter

Aurora Meter meters usage, enforces plan limits and keeps prepaid credits for a
Phoenix or Elixir app. It is a library inside the host app: the host owns the
data. Full docs: https://hexdocs.pm/aurora_meter

## Setup

- Configure `config :aurora_meter, repo: MyApp.Repo, pubsub: MyApp.PubSub, plans: MyApp.Plans`.
  `:repo` is the Ecto repo module; `:pubsub` is the PubSub server *name*, never
  the `Phoenix.PubSub` module.
- Start `AuroraMeter` in the supervision tree after the Repo and PubSub and
  before the Endpoint.
- Generate the schema with `mix aurora_meter.gen.migration -r MyApp.Repo`, never
  by hand. Upgrades use `--from N` or `--upgrade`.
- Declare plans with `use AuroraMeter.Plans` and the DSL (`plan`, `price`,
  `limit`, `metered`, `counter`, `feature`, `recurring_credits`). Add
  `:aurora_meter` to `import_deps` in `.formatter.exs`.

## Tenants

- Every call takes a tenant first: the organisation or account that owns the
  subscription, not the individual user unless the user is the customer.
- Strings, integers and atoms work as keys. For a struct (an Ecto schema, a
  Phoenix 1.8 `%Scope{}`), implement `AuroraMeter.Tenant` and set
  `config :aurora_meter, tenant: MyApp.AuroraTenant`. Include a
  `def to_key(key) when is_binary(key), do: key` clause.
- Resolve the tenant from the session or an authenticated assign, never from
  request params.
- Subscribe, track and check with the same tenant term.

## Metering and limits

- DO use `AuroraMeter.with_quota(tenant, feature, fun)` to gate and meter in one
  step. It returns `{:ok, result} | {:error, :limit_exceeded} | {:error, :not_entitled}`.
- DO use `AuroraMeter.track/4` for usage that is counted, not gated.
- DO use `AuroraMeter.record/4` with a caller-supplied `id:` for usage you
  invoice. Retry an unknown outcome with the same `id` and the same payload
  (including `occurred_at`).
- DON'T assume a hard cap is exact across a cluster: each node enforces against
  its own view, so a burst can overshoot by about one `:broadcast_interval`.
- DON'T call Ecto or write to the `aurora_meter_*` tables directly.
- DON'T mark a feature both `:events` (in `feature_sources`) and tracked with
  `track/4`: a feature has one reporting source.

## Credits

- Amounts are integer micro-dollars (`1_000_000` is one dollar). Use
  `AuroraMeter.Credits.Money` to convert; never use floats.
- DO wrap paid work in `AuroraMeter.Credits.with_credits(tenant, estimate, reference, fun)`;
  `fun` returns `{:ok, result, actual_cost}` or `{:error, reason}`. It refuses
  with `{:error, :insufficient_credits}` before running `fun`.
- DO pass a stable, unique `reference:` to `grant/3` (for example
  `"stripe:pi_123"`) so a retried grant is not applied twice.
- DON'T bill from a telemetry handler: it cannot hold or refuse, and runs after
  the work is done.

## LiveView

- Pass the quota map to components (`<.usage_meter quota={@quota} />`), not a
  tenant: a component only re-renders when its assigns change.
- Subscribe on the connected mount only:
  `if connected?(socket), do: AuroraMeter.LiveView.subscribe(org)`, then in
  `handle_info/2` call
  `AuroraMeter.LiveView.assign_quota(message, socket, :quota, :feature)`.
- The helpers take the message first and the socket second.

## Tests

- Set `flush_interval` and `broadcast_interval` to an hour in `config/test.exs`
  and drive them with `AuroraMeter.Test.flush!/0` and `broadcast!/0`.
- The flush runs in the `AuroraMeter.Flusher` process: in an async test, allow it
  on the sandbox connection, or use `async: false` with shared mode.
- Use `AuroraMeter.Test.with_clock/2` to freeze time; it is global, so only in
  `async: false` tests.

## Billing

The free core does not take payments. Stripe checkout, top-ups, auto-recharge
and metered invoicing are in Aurora Meter Pro: https://aurorameter.com/pro
