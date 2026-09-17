import Config

# The Pro profile's configuration.
#
# Imported from `config/runtime.exs` **only** when `AURORA_SAMPLE_PRO=1`, so a
# reader without the flag never evaluates a line of it and never has to have any
# of these variables set.
#
# Two rules govern the whole file:
#
#   1. **Every value comes from the environment and no default is a
#      credential.** There is no fallback key, no fallback secret and no
#      "development" value that happens to work. A missing variable stops the
#      boot and names itself.
#   2. **A value of the wrong shape stops the boot before anything reaches
#      Stripe.** Stripe's key prefixes are structural: `sk_live_` cannot be
#      mistaken for `sk_test_` by any amount of tiredness. This file refuses on
#      the prefix and prints the prefix it wanted, never any part of what it
#      found.
#
# The refusals are raises at configuration time, which is deliberate: a
# configuration error that becomes a log line is a configuration error that
# reaches production.

# Reads a required variable, or stops the boot naming it.
fetch! = fn name, hint ->
  case System.get_env(name) do
    value when is_binary(value) and value != "" ->
      value

    _absent ->
      raise """
      #{name} is not set, and the Pro profile needs it.

      #{hint}

      Copy examples/aurora_meter_example_ai/.env.example to .env, fill in your
      own TEST-MODE values, and source it:

          set -a; . ./.env; set +a

      Or run the core profile instead, which needs none of this:

          unset AURORA_SAMPLE_PRO
      """
  end
end

# Reads a required variable and checks its prefix. The value is never echoed,
# in whole or in part: the message names the variable and the prefix that was
# expected, which is everything a reader needs and nothing they should not have
# on their terminal or in their scrollback.
fetch_prefixed! = fn name, prefix, hint ->
  value = fetch!.(name, hint)

  if String.starts_with?(value, prefix) do
    value
  else
    raise """
    #{name} does not begin #{prefix}.

    The Pro profile of this sample is TEST MODE ONLY. It refuses on the prefix
    rather than trusting a comment or a habit, because Stripe's key prefixes
    are structural and a mistake here moves real money.

    Nothing of the value you supplied is printed here, deliberately. And
    nothing has been sent to Stripe: this refusal happens while configuration
    is being read, before the application starts.
    """
  end
end

# ---------------------------------------------------------------------------
# Stripe, test mode only
# ---------------------------------------------------------------------------

secret_key =
  fetch_prefixed!.(
    "STRIPE_SECRET_KEY",
    "sk_test_",
    "It is the Stripe secret key the sample's Pro profile bills with."
  )

publishable_key =
  fetch_prefixed!.(
    "STRIPE_PUBLISHABLE_KEY",
    "pk_test_",
    "It is the key the checkout redirect is built with."
  )

webhook_secret =
  fetch_prefixed!.(
    "STRIPE_WEBHOOK_SECRET",
    "whsec_",
    "Get it from `stripe listen --print-secret`. It is the secret that signs the events the CLI forwards, and it is not any registered endpoint's secret."
  )

api_version =
  fetch!.(
    "STRIPE_API_VERSION",
    "Pin the provider contract this run is tested against, for example 2025-08-27.basil. There is deliberately no default: the evidence a proof run writes records which contract was tested, and a default would make that record a guess."
  )

account_id =
  fetch!.(
    "AURORA_STRIPE_ACCOUNT_ID",
    "The acct_... this key reaches. Aurora Meter Pro puts it in every outbox item's identity and confirms it against the account the key actually reaches, so there is no safe default. The 09d build document's variable table does not list it; Pro's boot check requires it."
  )

meter_id =
  fetch!.(
    "AURORA_STRIPE_METER_ID",
    "The mtr_... of the Billing Meter that receives token usage. It is read when a meter event summary is reconciled."
  )

meter_event_name =
  fetch!.(
    "AURORA_STRIPE_METER_EVENT",
    "The Billing Meter's event NAME, which is what a meter event is sent under. It is a different value from the meter id and Pro needs both: one to send, one to read back."
  )

price_tokens =
  fetch!.(
    "AURORA_STRIPE_PRICE_TOKENS",
    "The metered price_... bound to that meter, for the :studio plan."
  )

price_studio =
  fetch!.(
    "AURORA_STRIPE_PRICE_STUDIO",
    "The recurring price_... for the :studio plan's flat component."
  )

credits_product =
  fetch!.(
    "AURORA_STRIPE_CREDITS_PRODUCT",
    "The prod_... a credit top-up is charged against."
  )

config :stripity_stripe, api_key: secret_key

config :aurora_meter_example_ai, stripe_publishable_key: publishable_key

# ---------------------------------------------------------------------------
# Aurora Meter Pro
# ---------------------------------------------------------------------------

config :aurora_meter_pro,
  stripe_account_id: account_id,
  stripe_mode: :test,
  # The account assertion is the check that catches a key pointed at somebody
  # else's account. `:require` rather than `:best_effort`, because this profile
  # is only ever run by hand with the network up, and a run that silently
  # skipped the assertion would prove less than it appears to.
  stripe_account_check: :require,
  api_version: api_version,
  webhook_secret: webhook_secret,
  stripe_meters: %{tokens: meter_event_name},
  stripe_meter_ids: %{tokens: meter_id},
  stripe_prices: %{studio: price_studio},
  stripe_metered_prices: %{studio: price_tokens},
  credits_product_id: credits_product,
  # Test mode still charges a real card object, so the presets are small.
  credits_presets_cents: [500, 1_000, 2_500],
  credits_min_cents: 500,
  credits_max_cents: 5_000,
  # Short enough that the auto-recharge recipe can be watched in one sitting.
  # A production value is minutes, not seconds, and `docs/failures.md` says so
  # where the recipe uses it.
  auto_top_up_cooldown_seconds: 30,
  auto_top_up_max_failures: 3

# ---------------------------------------------------------------------------
# The billing provider and the outbox
# ---------------------------------------------------------------------------
#
# `provider:` is a core seam with a no-op default; naming Pro's implementation
# is what makes `AuroraMeter.Billing.checkout/3` and `portal_url/2` reach
# Stripe. Nothing in `lib/aurora_meter_example_ai/` calls Stripe directly.
config :aurora_meter, provider: AuroraMeter.Pro.Stripe

# The outbox, and the correction this line had to make.
#
# The obvious value here is `AuroraMeter.Pro.Outbox`, and that is what was
# written first: one line, the free export path becomes the commercial one,
# and `lib/aurora_meter_example_ai/generations.ex` does not change. All of that
# is true and it is not the whole story.
#
# `AuroraMeter.record/4` calls **one** outbox. Pointing it at Pro's therefore
# stops staging the sample's own `sample_outbox_items` row, and five things
# this application had built on that row stopped working at once: the orphan
# recovery path in `Generations`, `AuroraMeterExampleAi.HoldPolicy`,
# `mix sample.repair`, four figures on `/ops`, and five of the eight recipes in
# `docs/failures.md`. Thirty-one tests went red the moment the flag was set,
# which is how this was found.
#
# So the value is a three-line module that calls both, in the one transaction:
# this application keeps its own durable record of what it metered, and Pro
# gets its delivery queue. See `AuroraMeterExampleAi.Pro.Outbox` for why that
# is the right answer rather than rewriting the five call sites against a
# commercial package's tables.
config :aurora_meter, events_outbox: AuroraMeterExampleAi.Pro.Outbox

# ---------------------------------------------------------------------------
# Oban
# ---------------------------------------------------------------------------
#
# Pro's scheduled work is Oban work and the host owns the crontab. Both
# packages' workers share the `:aurora_meter` queue, and both publish their
# recommended entries rather than registering them behind the host's back.
config :aurora_meter_example_ai, Oban,
  repo: AuroraMeterExampleAi.Repo,
  queues: [aurora_meter: 5],
  plugins: [
    {
      Oban.Plugins.Cron,
      # `:usage_reporter` is EXCLUDED, and the reason is worth the paragraph.
      #
      # This application declares `feature_sources: %{tokens: :events}`: the
      # billable fact for tokens is the durable event, and it is exported
      # through the events outbox. `AuroraMeter.Pro.UsageReporter` is the
      # other export path, the one that reports a metered feature from the
      # buffered counter, and running both means reporting the same usage
      # twice from two different sources.
      #
      # Taking the recommended crontab whole does exactly that, and the way
      # it announces itself is not a double bill but a **refusal to boot**:
      # the reporter writes one `aurora_meter_usage_reports` row, and the
      # next node to start finds it and raises
      # `AuroraMeter.Pro.CutoverRequiredError` ("this feature has already
      # been reported to a provider from the buffered counter"). Which is
      # the check doing its job on a row this installation should never have
      # had. Found by the real-provider proof run, not by reading.
      #
      # Reported against Pro rather than worked around silently: see
      # `open-findings.md`.
      crontab:
        AuroraMeter.Oban.cron_entries() ++
          AuroraMeter.Pro.cron_entries(exclude: [:usage_reporter])
    }
  ]
