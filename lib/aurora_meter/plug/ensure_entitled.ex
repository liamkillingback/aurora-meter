if Code.ensure_loaded?(Plug.Conn) do
  defmodule AuroraMeter.Plug.EnsureEntitled do
    @moduledoc """
    **This check is advisory.** It refuses a request the plan plainly does not
    allow, before your controller runs. It does not hold anything, and between
    its decision and your controller's work another request on the same node can
    take the last unit.

    The only strict admission is `AuroraMeter.with_quota/4` around the work
    itself, and **no reserving plug is shipped, deliberately**. A reservation has
    to be released when the work fails, `with_quota/4` releases it by running the
    work inside its own `try/catch`, and a plug cannot see what the controller
    returned or whether it raised. A plug that reserved would hold quota it could
    never give back for every failed action (invariant I03), and would admit N
    concurrent requests whose controllers each reserved again on top (invariant
    I04). Use both: the plug for the cheap early refusal and the clear 403, and
    `with_quota/4` where the money is.

    It is **not authorization**. It answers "does this tenant's plan allow this
    feature", never "is this request allowed to act for this tenant". The second
    question is permanently yours, and the `:tenant` resolver is required with no
    default so that it is asked explicitly. A resolver that returns `nil` gets a
    401 and nothing is written: an unresolved tenant is never the default tenant.

        pipeline :metered do
          plug AuroraMeter.Plug.EnsureEntitled,
            feature: :api_calls,
            tenant: &MyAppWeb.Tenancy.current_org/1
        end

    ## Options

    | Option | Type | Default | Meaning |
    |---|---|---|---|
    | `:feature` | atom, required | none | the feature to check; a binary is refused at compile time |
    | `:tenant` | `(Plug.Conn.t() -> tenant \\| nil)` or `{module, function}`, required | none | your resolver; there is no default |
    | `:mode` | `:check \\| :entitled?` | `:check` | `:check` consults usage, so it sees hard limits; `:entitled?` consults only the plan shape and reads no counter |
    | `:assign_quota` | boolean | `true` | assign `:aurora_meter_quota` on a passing request |
    | `:on_missing_tenant` | `:unauthorized \\| {module, function}` | `:unauthorized` | 401, reason `:missing_tenant` |
    | `:on_denied` | `:forbidden \\| {module, function}` | `:forbidden` | 403, reason `:not_entitled` or `:limit_exceeded` |
    | `:on_unavailable` | `:service_unavailable \\| {module, function}` | `:service_unavailable` | 503, reason `:unavailable` |

    `init/1` validates its options, and Phoenix expands a router `plug` call at
    compile time, so a bad option is a compile error in your application rather
    than a surprise on the first request.

    ## What a passing request gets

    `:aurora_meter_tenant`, the term your resolver returned, and (unless
    `assign_quota: false`) `:aurora_meter_quota`, exactly
    `AuroraMeter.quota(tenant, feature)`. The quota costs one more ETS read and
    one period computation than the decision does; turn it off on a hot path
    that does not render it.

    ## What a refused request gets

    The bare atoms send an empty body and halt, with the reason atom in
    `conn.private[:aurora_meter_denial]` so a downstream error handler or your
    endpoint can render whatever your API renders. The plug picks no content
    type and writes no body of its own, because it does not know whether your
    client wants JSON.

    Pass `{module, function}` to render it yourself. It is called with
    `(conn, reason)` and **must return a halted conn**; one that does not raises
    a `RuntimeError` naming your callback, because an unhalted conn after a
    denial is a request that was refused and then served anyway.

        plug AuroraMeter.Plug.EnsureEntitled,
          feature: :api_calls,
          tenant: {MyAppWeb.Tenancy, :current_org},
          on_denied: {MyAppWeb.Errors, :quota_json}

    **Why 403 and not 429.** `:limit_exceeded` is an entitlement outcome for the
    current period, not a rate limit that clears in seconds, so a `Retry-After`
    would be a lie. Both denial reasons default to 403 and the reason atom is
    carried through to your callback, so mapping `:limit_exceeded` to 402 or 429
    is one clause in one place.

    ## Errors it does not hide

    `AuroraMeter.UndeclaredFeatureError` (you asked about a feature no plan
    declares, under `undeclared_feature_policy: :raise`) and
    `AuroraMeter.Period.InvalidPeriodError` (your period source returned
    something that is not a period) are **host configuration errors** and are
    re-raised with their original stacktrace. So is anything your `:tenant`
    resolver raises, and anything your `AuroraMeter.Tenant` module raises about
    the term it returned: the plug resolves the tenant key before it takes the
    decision, precisely so that a term your tenant module cannot handle reaches
    your error handler rather than becoming a 503 that sends an operator to look
    at a database that is perfectly well.

    Everything else raised while taking the decision, a database that cannot be
    reached during a cold counter seed being the one that happens, is logged at
    `:error` and becomes the unavailable path, so a 503 is never silent.

    ## Mounting it twice

    Harmless and pointless. The decision is idempotent, consumes nothing and
    writes nothing, so a plug mounted in a pipeline and again in a controller
    takes it twice and assigns twice.

    Compiled only when `Plug.Conn` is available. A host that adds `plug` after
    compiling `aurora_meter` needs `mix deps.compile aurora_meter --force`.
    """

    @behaviour Plug

    require Logger

    alias AuroraMeter.Period.InvalidPeriodError
    alias AuroraMeter.UndeclaredFeatureError
    alias Plug.Conn

    @schema NimbleOptions.new!(
              feature: [
                type: :atom,
                required: true,
                doc: "The feature to check. An atom: the package never calls String.to_atom/1."
              ],
              tenant: [
                type: {:or, [{:fun, 1}, {:tuple, [:atom, :atom]}]},
                required: true,
                doc:
                  "How to find the tenant for this request: a one-argument function or a " <>
                    "`{module, function}` pair, called with the conn, returning the tenant " <>
                    "term or nil. There is no default, because which tenant a request may " <>
                    "act for is an authorization question and it is yours."
              ],
              mode: [
                type: {:in, [:check, :entitled?]},
                default: :check,
                doc:
                  "`:check` consults usage and therefore sees hard limits; `:entitled?` " <>
                    "consults only the plan shape and reads no counter."
              ],
              assign_quota: [
                type: :boolean,
                default: true,
                doc: "Whether a passing request gets `:aurora_meter_quota`."
              ],
              on_missing_tenant: [
                type: {:or, [{:in, [:unauthorized]}, {:tuple, [:atom, :atom]}]},
                default: :unauthorized
              ],
              on_denied: [
                type: {:or, [{:in, [:forbidden]}, {:tuple, [:atom, :atom]}]},
                default: :forbidden
              ],
              on_unavailable: [
                type: {:or, [{:in, [:service_unavailable]}, {:tuple, [:atom, :atom]}]},
                default: :service_unavailable
              ]
            )

    @typedoc "Why the plug halted."
    @type denial :: :missing_tenant | :not_entitled | :limit_exceeded | :unavailable

    @doc """
    Validates and freezes the options. Raises `NimbleOptions.ValidationError` on
    an unknown option, a missing `:feature` or `:tenant`, or a `:feature` that is
    not an atom.
    """
    @impl Plug
    @spec init(keyword()) :: map()
    def init(opts) do
      opts
      |> NimbleOptions.validate!(@schema)
      |> Map.new()
    end

    @doc """
    Takes the decision and either assigns and continues, or halts.

    Never reserves, never holds credit and never writes.
    """
    @impl Plug
    @spec call(Conn.t(), map()) :: Conn.t()
    def call(conn, opts) do
      case resolve_tenant(conn, opts.tenant) do
        nil ->
          # Before anything else, and before `AuroraMeter.Tenant.to_key/1` can
          # see it. `Tenant.Default.to_key/1` stringifies, so `nil` would become
          # `""`, which in the 0.5.x transition mode is a warning rather than a
          # refusal (`open-findings.md` C12), and the request would then be
          # checked against the empty-string tenant's counters. Nothing is read
          # and nothing is written on this path.
          deny(conn, :missing_tenant, opts.on_missing_tenant, 401)

        tenant ->
          # Resolve the key here, deliberately outside `decide/2`'s
          # classification. A host whose `AuroraMeter.Tenant` module refuses the
          # term, or whose term has no `String.Chars`, has a configuration fault
          # of exactly the kind `UndeclaredFeatureError` is, and a 503 would send
          # an operator to look at a database that is perfectly well. The value
          # is discarded: nothing here logs a tenant key.
          _key = AuroraMeter.Tenant.to_key(tenant)

          respond(conn, tenant, opts)
      end
    end

    # The decision and the response are separate on purpose. `decide/2` is
    # wrapped in a rescue that classifies a failure of the DECISION; the response
    # must not be inside it. When it was, `assert_halted!/4`'s RuntimeError,
    # which exists to refuse a denial callback that would let a refused request
    # through, was caught by that rescue and turned into a 503: the rule the
    # moduledoc states was unenforceable, and a host would have seen a confusing
    # 503 instead of the message naming its callback. Both tests for it failed
    # with "Expected exception RuntimeError but nothing was raised".
    @spec respond(Conn.t(), term(), map()) :: Conn.t()
    defp respond(conn, tenant, opts) do
      case decide(tenant, opts) do
        {:ok, assigns} ->
          Enum.reduce(assigns, conn, fn {key, value}, acc -> Conn.assign(acc, key, value) end)

        {:denied, reason} ->
          deny(conn, reason, opts.on_denied, 403)

        {:unavailable, error, stacktrace} ->
          Logger.error(
            "AuroraMeter.Plug.EnsureEntitled could not decide #{inspect(opts.feature)}: " <>
              Exception.format(:error, error, stacktrace)
          )

          deny(conn, :unavailable, opts.on_unavailable, 503)
      end
    end

    @spec decide(term(), map()) ::
            {:ok, keyword()}
            | {:denied, denial()}
            | {:unavailable, Exception.t(), Exception.stacktrace()}
    defp decide(tenant, opts) do
      case entitlement(tenant, opts) do
        :ok -> {:ok, allow_assigns(tenant, opts)}
        {:error, reason} -> {:denied, reason}
      end
    rescue
      # Host configuration errors, re-raised with the original stacktrace. A 503
      # would tell an operator the database is unwell when the actual fault is a
      # feature nobody declared or a period source returning a non-period, and
      # both are fixed in the host rather than waited out.
      error in [UndeclaredFeatureError, InvalidPeriodError] ->
        reraise(error, __STACKTRACE__)

      error ->
        {:unavailable, error, __STACKTRACE__}
    end

    @spec entitlement(term(), map()) :: :ok | {:error, :not_entitled | :limit_exceeded}
    defp entitlement(tenant, %{mode: :check, feature: feature}),
      do: AuroraMeter.check(tenant, feature)

    defp entitlement(tenant, %{mode: :entitled?, feature: feature}) do
      if AuroraMeter.entitled?(tenant, feature), do: :ok, else: {:error, :not_entitled}
    end

    # Built inside the classified region, because `quota/2` reads the counter
    # and can hit the storage adapter on a cold row exactly as `check/2` can.
    @spec allow_assigns(term(), map()) :: keyword()
    defp allow_assigns(tenant, opts) do
      if opts.assign_quota do
        [
          aurora_meter_tenant: tenant,
          aurora_meter_quota: AuroraMeter.quota(tenant, opts.feature)
        ]
      else
        [aurora_meter_tenant: tenant]
      end
    end

    @spec resolve_tenant(Conn.t(), (Conn.t() -> term()) | {module(), atom()}) :: term()
    defp resolve_tenant(conn, fun) when is_function(fun, 1), do: fun.(conn)
    defp resolve_tenant(conn, {module, function}), do: apply(module, function, [conn])

    @spec deny(Conn.t(), denial(), :unauthorized | :forbidden | :service_unavailable, 401..599) ::
            Conn.t()
    defp deny(conn, reason, handler, status) do
      conn = Conn.put_private(conn, :aurora_meter_denial, reason)

      case handler do
        atom when is_atom(atom) ->
          conn |> Conn.send_resp(status, "") |> Conn.halt()

        {module, function} ->
          assert_halted!(apply(module, function, [conn, reason]), module, function, reason)
      end
    end

    # A callback that forgets to halt turns a refusal into a request that is
    # served anyway, and it does so silently: the conn looks fine, the pipeline
    # continues and the controller runs. This is the rule the moduledoc states,
    # asserted rather than asked for.
    @spec assert_halted!(term(), module(), atom(), denial()) :: Conn.t()
    defp assert_halted!(%Conn{halted: true} = conn, _module, _function, _reason), do: conn

    defp assert_halted!(%Conn{halted: false}, module, function, reason) do
      raise RuntimeError,
            "#{inspect(module)}.#{function}/2 was called by " <>
              "AuroraMeter.Plug.EnsureEntitled to refuse a request (#{inspect(reason)}) and " <>
              "returned a conn that is not halted. The request would continue to the " <>
              "controller as though it had been allowed. Call Plug.Conn.halt/1 on the conn " <>
              "you return."
    end

    defp assert_halted!(other, module, function, reason) do
      raise RuntimeError,
            "#{inspect(module)}.#{function}/2 was called by " <>
              "AuroraMeter.Plug.EnsureEntitled to refuse a request (#{inspect(reason)}) and " <>
              "returned #{inspect(other, limit: 3)} instead of a halted Plug.Conn."
    end
  end
end
