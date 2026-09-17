import Config

# The Pro profile under test: the same wiring as `config/pro.exs`, with the
# provider seams pointed at Aurora Meter Pro's own fakes.
#
# Imported from `config/test.exs` only when `AURORA_SAMPLE_PRO=1`.
#
# ## Why this is a separate file from config/pro.exs
#
# `config/pro.exs` refuses to load without a real Stripe test-mode key, and it
# should: a development or production boot that silently fell back to a fake
# would be an application that looks like it is billing and is not. A test run
# is the one context where the opposite is true, because a suite that needed a
# credential could not run in CI at all and a suite that made real Stripe calls
# would be neither fast nor idempotent.
#
# So the two files are the two answers to the same question, and the question
# is asked in `config/test.exs` and `config/runtime.exs` rather than inside
# either file.
#
# **Nothing here is a credential.** The webhook secret below is assembled from
# a prefix and a run of letters at load time, which is not fastidiousness:
# `test/secret_scan_test.exs` walks every file in this tree looking for exactly
# the shape `whsec_` plus eight or more key characters, and a literal here
# would make the scan find itself and acquire an exclusion list. The same trick
# is in the scan test and in `AuroraMeterExampleAi.Redact`, for the same
# reason, and each of them says so.

config :aurora_meter_pro,
  # Pro's own deterministic, network-free provider doubles. Both are in Pro's
  # `lib/`, not in its test support, so a host gets them.
  credits_stripe_client: AuroraMeter.Pro.Credits.StripeClient.Fake,
  stripe_meter_client: AuroraMeter.Pro.Stripe.Fake,
  stripe_adjustment_client: AuroraMeter.Pro.Stripe.Fake,
  stripe_summary_client: AuroraMeter.Pro.Stripe.Fake,
  stripe_subscription_client: AuroraMeter.Pro.Stripe.Fake,
  stripe_invoice_client: AuroraMeter.Pro.Stripe.Fake,
  stripe_account_client: AuroraMeter.Pro.Stripe.Fake,
  # An account id with the right shape and no meaning. The account assertion is
  # skipped rather than pointed at a fake that would always agree: a check that
  # cannot fail proves nothing, and saying it is off is more honest than
  # running it against a double.
  stripe_account_id: "acct_" <> String.duplicate("t", 16),
  stripe_mode: :test,
  stripe_account_check: :skip,
  api_version: "2025-08-27.basil",
  webhook_secret: "whsec_" <> String.duplicate("t", 32),
  stripe_meters: %{tokens: "aurora_sample_tokens"},
  stripe_meter_ids: %{tokens: "mtr_" <> String.duplicate("t", 16)},
  stripe_prices: %{studio: "price_" <> String.duplicate("s", 14)},
  stripe_metered_prices: %{studio: "price_" <> String.duplicate("m", 14)},
  credits_product_id: "prod_" <> String.duplicate("p", 14),
  credits_presets_cents: [500, 1_000, 2_500],
  credits_min_cents: 500,
  credits_max_cents: 5_000,
  auto_top_up_cooldown_seconds: 0,
  auto_top_up_max_failures: 3,
  # The audit log is written synchronously under test, so an assertion about a
  # recovery action does not race the writer.
  audit_log_writer: :sync

config :aurora_meter,
  provider: AuroraMeter.Pro.Stripe,
  events_outbox: AuroraMeterExampleAi.Pro.Outbox

config :aurora_meter_example_ai, stripe_publishable_key: "pk_test_" <> String.duplicate("t", 16)

# Oban runs nothing on its own in the suite. `testing: :manual` means a job is
# inserted and not executed, and a test that wants one run calls
# `Oban.Testing.perform_job/3`, which is the difference between a suite that is
# deterministic and one that is usually deterministic.
config :aurora_meter_example_ai, Oban,
  repo: AuroraMeterExampleAi.Repo,
  testing: :manual,
  queues: false,
  plugins: false
