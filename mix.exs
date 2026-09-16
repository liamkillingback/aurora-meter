defmodule AuroraMeter.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/liamkillingback/aurora-meter"

  def project do
    [
      app: :aurora_meter,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      lockfile: lockfile(),
      aliases: aliases(),
      name: "Aurora Meter",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      dialyzer: dialyzer(),
      test_coverage: test_coverage(),
      test_ignore_filters: test_ignore_filters()
    ]
  end

  # `test/regressions/seeds/*.exs` are saved ledger histories, not test modules:
  # `AuroraMeter.CreditsRegressionsTest` reads each one with `Code.eval_file/1`
  # and generates a replay test for it. Elixir 1.20 warns on every `mix test`
  # about any `.exs` under the test path that matches neither `:test_load_filters`
  # nor this list, so they are declared here rather than left to nag. The
  # directory is otherwise untouchable: build unit 01e's rule is that a seed file
  # is never deleted to make a suite green.
  defp test_ignore_filters do
    [~r{regressions/seeds/.*\.exs$}]
  end

  # The threshold is a *measured* floor, not an aspiration: it is
  # `floor(total) - 2` from the run recorded in
  # `docs/evidence/v1/phase-01/coverage.md`, with the command and the commit that
  # produced it. Two points of headroom absorb adding a module before its tests;
  # they are not enough to hide a deleted test suite. Never raise or lower it from
  # a number that is not in that file.
  #
  # It is enforced by `mix coverage` on the pinned-tooling CI leg only. A
  # minimum-runtime leg stays on plain `mix test`: a coverage threshold failing
  # there would be a tooling exemption inverted into a false failure, while a
  # failing *test* there still fails, which is what the runtime claim needs.
  defp test_coverage do
    [
      summary: [threshold: 90],
      ignore_modules: [
        # Test fixtures compiled from test/support by elixirc_paths(:test).
        AuroraMeter.TestRepo,
        AuroraMeter.TestPlans,
        AuroraMeter.DataCase,
        # Existing fault double, and the fault harness that grows beside it.
        AuroraMeter.AmbiguousStorage,
        ~r/^AuroraMeter\.Test\./,
        # Run by `mix test.setup`, a separate Mix invocation that finishes before
        # --cover starts its cover server. Their real proof is the migration
        # matrix, which runs in its own OS processes.
        ~r/^AuroraMeter\.Migration\.V\d+$/,
        # Mix tasks are exercised by their own tests under test/mix. The install
        # task needs Igniter, which is optional, so it is zero on the headless
        # leg and would make the floor depend on the optional-dependency matrix.
        ~r/^Mix\.Tasks\./
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        check: :test,
        coverage: :test,
        "test.setup": :test,
        "v1.migrations": :test,
        "v1.faults": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Runtime deps are deliberately minimal. Phoenix LiveView/HTML are OPTIONAL —
  # the core is usable headless and they only light up the usage components.
  # They and Igniter live in optional_deps/0 below, because the `headless` CI leg
  # has to be able to remove them.
  defp deps do
    [
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.2"},
      {:nimble_options, "~> 1.1"},
      {:jason, "~> 1.4"},

      # Dev/test tooling — never shipped to consumers. ex_doc and dialyxir are
      # available in :test too so the `check` alias (which runs in :test) can
      # build docs and run dialyzer in one pass.
      {:ex_doc, "~> 0.31", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:floki, ">= 0.30.0", only: :test}
    ] ++ optional_deps()
  end

  # `optional: true` affects CONSUMERS, not this project: a plain `mix deps.get`
  # here fetches and compiles all four, so the flag alone cannot produce a
  # headless build of Aurora Meter itself. AURORA_HEADLESS=1 removes them, which
  # is what lets the `headless` CI leg prove decision D03 and invariant I20: a
  # host with none of them present compiles, installs and runs.
  #
  # AURORA_LIVEVIEW pins one half of the declared LiveView range so each half can
  # be exercised on its own. See .github/workflows/ci.yml and
  # docs/evidence/v1/phase-01/ci.md. Both variables are build switches for this
  # repository's CI, not a consumer API, and both default to absent.
  defp optional_deps do
    if System.get_env("AURORA_HEADLESS") == "1" do
      []
    else
      [
        {:phoenix_live_view, live_view_requirement(), optional: true},
        {:phoenix_html, "~> 3.3 or ~> 4.0", optional: true},
        # Optional: powers the one-step `mix aurora_meter.install`. Hosts without
        # it get the print-the-steps fallback.
        {:igniter, "~> 0.8", optional: true},
        # Optional: powers the `AuroraMeter.Oban.*` workers. Every operation they
        # wrap is public and directly callable, so a host with another scheduler
        # (or none) loses nothing, and the whole namespace is compiled behind
        # `if Code.ensure_loaded?(Oban)`. The floor is the one Aurora Meter Pro
        # already declares, so no existing Pro host is asked to move.
        {:oban, "~> 2.17", optional: true}
      ] ++ optional_metrics() ++ optional_dashboard() ++ optional_otel()
    end
  end

  # `telemetry_metrics` has a switch of its own as well as being swept away by
  # AURORA_HEADLESS, and the reason is Aurora Meter Pro rather than core.
  #
  # Pro requires Oban and ships LiveView components, so "Pro installed, core
  # built without Oban" is not a deployment anybody can have: AURORA_HEADLESS is
  # read by THIS file too, and core is Pro's path dependency, so setting it for
  # a Pro build strips core's four optional dependencies and Pro's own modules
  # then reference `AuroraMeter.Oban.*` and `AuroraMeter.Components`, which are
  # no longer compiled. Pro's headless leg could not compile at all, and the
  # incoherence was invisible until somebody ran it (`open-findings.md` X327).
  #
  # AURORA_NO_METRICS removes only this one, which IS a real configuration in
  # both packages: a host with a scheduler and a dashboard and no metrics
  # reporter. That is the configuration decision D12 and invariant I20 are about.
  #
  # `AuroraMeter.Telemetry.Metrics` is compiled behind
  # `if Code.ensure_loaded?(Telemetry.Metrics)`. Every event is emitted with or
  # without it; what a host loses is the preset list, not a signal. Both
  # supported majors are declared because hosts are split across them and
  # neither is deprecated.
  defp optional_metrics do
    if System.get_env("AURORA_NO_METRICS") == "1" do
      []
    else
      [{:telemetry_metrics, "~> 0.6 or ~> 1.0", optional: true}]
    end
  end

  # Optional: powers `AuroraMeter.LiveDashboard.Page`, compiled behind
  # `if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder)`. The page's data
  # readers (`AuroraMeter.LiveDashboard.Sections`) and its renderer
  # (`AuroraMeter.LiveDashboard.View`) are deliberately NOT behind this guard, so
  # everything the optional-dependency criteria are about stays testable in a
  # build without it.
  #
  # The requirement is the 0.8 line rather than "~> 0.8". For a two-segment
  # requirement `~> 0.8` means `>= 0.8.0 and < 1.0.0`, which would carry 0.9 as
  # well, and `Phoenix.LiveDashboard.PageBuilder`'s callback set has changed
  # across minor versions. Declaring a range wider than the one the matrix
  # resolves is a support claim nothing tests, which is what decision D12
  # forbids. The resolved version is recorded in
  # docs/evidence/v1/phase-08/08b-optional-integrations.md with the callback set
  # read from its source.
  #
  # AURORA_NO_DASHBOARD removes it on its own. AURORA_NO_METRICS removes it TOO,
  # and that is not tidiness: phoenix_live_dashboard declares
  # `telemetry_metrics` as a REQUIRED dependency, so leaving it installed would
  # pull telemetry_metrics back into the build and the switch named for removing
  # telemetry_metrics would remove nothing (`open-findings.md` X327's shape, one
  # dependency further out).
  defp optional_dashboard do
    if System.get_env("AURORA_NO_DASHBOARD") == "1" or
         System.get_env("AURORA_NO_METRICS") == "1" do
      []
    else
      [{:phoenix_live_dashboard, ">= 0.8.0 and < 0.9.0", optional: true}]
    end
  end

  # Optional: powers `AuroraMeter.OpenTelemetry`, compiled behind
  # `if Code.ensure_loaded?(:otel_tracer)`. The **API** and only the API: the
  # bridge starts no tracer provider, no exporter and no batch processor, and
  # opens no socket (decision D11). With the API present and no SDK configured,
  # its no-op tracer swallows everything, which is the documented headless
  # behaviour rather than an error.
  #
  # The SDK beside it is `only: :test` and is **not** optional and **not**
  # shipped: it exists so this repository's `otel` leg can assert the span shape
  # against a real tracer provider and a real in-memory exporter, rather than
  # against the `AuroraMeter.OpenTelemetry.Tracer` seam, which is this package's
  # own code. A consumer who wants spans installs `opentelemetry_api` and
  # whichever SDK and exporter they already run.
  #
  # AURORA_NO_OTEL removes the pair on its own; AURORA_HEADLESS removes them
  # with everything else. Narrow, and asserted narrow: the leg checks that Oban,
  # LiveView, Igniter, `telemetry_metrics` and `phoenix_live_dashboard` are all
  # still there (`open-findings.md` X327, X331).
  defp optional_otel do
    if System.get_env("AURORA_NO_OTEL") == "1" do
      []
    else
      [
        {:opentelemetry_api, "~> 1.2", optional: true},
        {:opentelemetry, "~> 1.3", only: :test}
      ]
    end
  end

  # The declared requirement is unchanged. Build unit 09b owns whether the
  # "~> 0.20" half survives (open-findings.md C9); this only lets CI resolve one
  # half at a time so that decision has evidence behind it.
  defp live_view_requirement do
    case System.get_env("AURORA_LIVEVIEW") do
      nil -> "~> 0.20 or ~> 1.0"
      "" -> "~> 0.20 or ~> 1.0"
      "1.0" -> "~> 1.0"
      "0.20" -> "~> 0.20"
      other -> Mix.raise("AURORA_LIVEVIEW must be \"1.0\" or \"0.20\", got: #{inspect(other)}")
    end
  end

  # A LiveView leg resolves a different dependency set from the committed lock,
  # so it resolves into its own lock file outside the working tree. mix.lock is
  # then untouchable by any leg, locally as well as in CI, and no leg can commit
  # a lock change by accident.
  defp lockfile do
    case System.get_env("AURORA_LIVEVIEW") do
      nil -> "mix.lock"
      "" -> "mix.lock"
      version -> Path.join(System.tmp_dir!(), "aurora_meter-liveview-#{version}.lock")
    end
  end

  defp description do
    "Real-time usage metering, plan entitlements, and Stripe-ready billing " <>
      "primitives for Phoenix: count, gate, and bill on the BEAM. The free core of " <>
      "aurorameter.com."
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Liam Killingback"],
      links: %{
        "Website" => "https://aurorameter.com",
        "Aurora Meter Pro" => "https://aurorameter.com/pricing",
        "GitHub" => @source_url,
        "PhxTemplates" => "https://www.phxtemplates.com"
      },
      # priv/ holds only the lib's own test-repo migration and dialyzer PLTs, so it
      # is deliberately excluded — consumers generate their migration via
      # `mix aurora_meter.gen.migration`, which embeds the template in code.
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md NOTICE.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "NOTICE.md",
        "docs/getting-started.md",
        "docs/api.md",
        "docs/guarantees.md",
        "docs/support-policy.md",
        "docs/correctness.md",
        "docs/upgrading-to-1.0.md",
        "docs/upgrading-to-lots.md",
        "docs/examples/concepts.md",
        "docs/examples/team-saas.md",
        "docs/examples/allowance-and-overage.md",
        "docs/examples/prepaid-credits.md",
        "docs/examples/events-source.md",
        "docs/examples/showing-usage.md",
        "docs/configuration.md",
        "docs/metering.md",
        "docs/storage-adapters.md",
        "docs/exporters.md",
        "docs/periods.md",
        "docs/entitlements.md",
        "docs/plans.md",
        "docs/credits.md",
        "docs/telemetry.md",
        "docs/alerts.md",
        "docs/operations.md",
        "docs/retention.md",
        "docs/operations/scheduler.md",
        "docs/operations/replay.md",
        "docs/testing.md",
        "docs/clustering.md",
        "docs/adr/0001-resolved-decisions.md",
        "docs/adr/0002-ets-counter-substrate.md",
        "docs/adr/0003-buffered-vs-durable-and-period-seam.md",
        "docs/adr/0004-cluster-wide-counters.md",
        "docs/adr/0005-prepaid-credit-ledger.md",
        "docs/adr/0006-counter-feature-kind.md",
        "docs/adr/0007-idempotent-flush-batches.md",
        "docs/adr/0008-pending-quota-work.md",
        # 0009, 0011 to 0014 and 0016 describe V1 design that has not shipped
        # and are deliberately absent: hexdocs would present a plan as a feature
        # (open-findings.md X85). Each is added by the release that ships it,
        # and test/aurora_meter/release_metadata_test.exs fails if one appears
        # here without being moved off its list.
        "docs/adr/0010-undeclared-features-and-config-strictness.md",
        "docs/adr/0015-period-contract-and-clock-seam.md"
      ],
      groups_for_extras: [
        # Reference is matched before Guides on purpose: ExDoc takes the first
        # group whose pattern matches, and the Guides pattern matches every
        # top-level file under docs/.
        Reference: ~r/docs\/(api|support-policy)\.md$/,
        Examples: ~r/docs\/examples\//,
        Operations: ~r/docs\/operations\//,
        Guides: ~r/docs\/[^\/]+$/,
        ADRs: ~r/docs\/adr\//
      ],
      groups_for_modules: groups_for_modules(),
      # These modules carry `@moduledoc false` on purpose, so ExDoc renders no
      # page for them and warns on every reference. docs/api.md still has to
      # name them: its "Internal modules" section is the statement that they are
      # not supported, and a boundary you cannot name is not a boundary. Listing
      # them here says "do not try to link to this", which is exactly true, and
      # keeps `mix docs` warning-free so a real broken reference still stands
      # out. Keep it equal to the `@moduledoc false` members of the Internal
      # group below.
      skip_code_autolink_to: [
        "AuroraMeter.BootChecks",
        "AuroraMeter.Config.Schema",
        "AuroraMeter.Credits.Allocator",
        "AuroraMeter.Credits.Ledger",
        "AuroraMeter.Credits.Promotions",
        "AuroraMeter.Credits.Reconciliation",
        "AuroraMeter.Credits.Series",
        "AuroraMeter.Install.Templates",
        "AuroraMeter.Migration.V1",
        "AuroraMeter.Migration.V2",
        "AuroraMeter.Migration.V3",
        "AuroraMeter.Migration.V4",
        "AuroraMeter.Migration.V5",
        "AuroraMeter.Migration.V6",
        "AuroraMeter.Migration.V7",
        "AuroraMeter.Migration.V8",
        "AuroraMeter.Migration.V9",
        "AuroraMeter.Migration.V10",
        "AuroraMeter.Plans.Snapshot",
        "AuroraMeter.Plans.Snapshot.canonical/1",
        "AuroraMeter.Schema.FlushReceipt",
        # `AuroraMeter.Retention` explains the receipt rule by naming the
        # function that writes the receipt, which is the only way a reader can
        # check the claim. The module is internal and carries `@moduledoc
        # false`, so ExDoc can resolve it and not link to it.
        "AuroraMeter.Storage.Ecto.flush_batch/3",
        "AuroraMeter.Subscriptions.Preview",
        "AuroraMeter.Subscriptions.Transitions",
        "AuroraMeter.Supervisor"
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      formatters: ["html"]
    ]
  end

  # The rendered form of the boundary in docs/api.md. The `Internal` list is the
  # one that carries a promise (or rather, withdraws one), so
  # test/aurora_meter/api_inventory_test.exs asserts it is byte-for-byte the
  # same set as that test's own `@internal_modules`, which is in turn the
  # "Internal modules" section of docs/api.md. A module with `@moduledoc false`
  # renders no page at all; it is listed anyway so the three lists stay one list.
  defp groups_for_modules do
    [
      "Core API": [
        AuroraMeter,
        AuroraMeter.Entitlements,
        AuroraMeter.Credits,
        AuroraMeter.Credits.Money,
        AuroraMeter.Billing,
        AuroraMeter.Config,
        AuroraMeter.Plans,
        AuroraMeter.Plan,
        AuroraMeter.Subscriptions,
        AuroraMeter.Events,
        AuroraMeter.Event,
        AuroraMeter.Flusher,
        AuroraMeter.Migration,
        AuroraMeter.LiveView,
        AuroraMeter.Components,
        AuroraMeter.Telemetry,
        AuroraMeter.Telemetry.Metrics
      ],
      # The seams a host implements, with their reference implementations and
      # their conformance suites beside them. `AuroraMeter.Storage` and
      # `AuroraMeter.Billing.Provider` moved here from "Behaviours" when the
      # exporter seam landed (build unit 04a): an author writing an adapter
      # needs the behaviour, the example and the suite on one page of the
      # sidebar, and "Behaviours" keeps the ones a host configures rather than
      # extends.
      "Extension seams": [
        AuroraMeter.Storage,
        AuroraMeter.StorageCase,
        AuroraMeter.Exporter,
        AuroraMeter.Exporter.Item,
        AuroraMeter.Exporter.Journal,
        AuroraMeter.ExporterCase,
        AuroraMeter.Billing.Provider
      ],
      Behaviours: [
        AuroraMeter.Credits.HoldReconciler,
        AuroraMeter.Events.Outbox,
        AuroraMeter.Tenant,
        AuroraMeter.Period,
        AuroraMeter.Clock
      ],
      Implementations: [
        AuroraMeter.Events.Outbox.Noop,
        AuroraMeter.Tenant.Default,
        AuroraMeter.Period.Calendar,
        AuroraMeter.Clock.System,
        AuroraMeter.Billing.Noop
      ],
      # Compiled only when Oban is installed, which is why the group can be
      # empty on a headless build. ExDoc ignores a group whose members are all
      # absent, so the docs build is the same either way.
      # Compiled only when phoenix_live_dashboard is installed, so this group can
      # be empty on a build without it. ExDoc ignores a group whose members are
      # all absent.
      Observability: [
        AuroraMeter.LiveDashboard.Page,
        AuroraMeter.OpenTelemetry
      ],
      Scheduling: [
        AuroraMeter.Oban,
        AuroraMeter.Oban.CreditExpiry,
        AuroraMeter.Oban.HoldReconciliation,
        AuroraMeter.Oban.EventsReplay,
        AuroraMeter.Oban.RecurringGrants,
        AuroraMeter.Oban.PlanTransitions
      ],
      Schemas: [
        AuroraMeter.Schema.Counter,
        AuroraMeter.Schema.History,
        AuroraMeter.Schema.Event,
        AuroraMeter.Schema.EventTotal,
        AuroraMeter.Schema.Subscription,
        AuroraMeter.Schema.CreditBalance,
        AuroraMeter.Schema.CreditTransaction
      ],
      Exceptions: [
        AuroraMeter.UndeclaredFeatureError,
        AuroraMeter.Period.InvalidPeriodError,
        AuroraMeter.Credits.CurrencyMismatchError,
        AuroraMeter.Oban.ConfigError
      ],
      "Test helpers": [
        AuroraMeter.Test,
        AuroraMeter.Clock.Fixed
      ],
      "Mix tasks": [
        Mix.Tasks.AuroraMeter.Bench,
        Mix.Tasks.AuroraMeter.Features,
        Mix.Tasks.AuroraMeter.Gen.Migration,
        Mix.Tasks.AuroraMeter.Install
      ],
      Internal: [
        AuroraMeter.BootChecks,
        AuroraMeter.Broadcaster,
        AuroraMeter.Cluster,
        AuroraMeter.Config.Schema,
        AuroraMeter.Counter,
        AuroraMeter.Credits.Allocator,
        AuroraMeter.Credits.Ledger,
        AuroraMeter.Credits.Promotions,
        AuroraMeter.Credits.Reconciliation,
        AuroraMeter.Credits.Series,
        AuroraMeter.Events.Backfill,
        AuroraMeter.Events.Canonical,
        AuroraMeter.Events.Gate,
        AuroraMeter.Install.Templates,
        AuroraMeter.LiveDashboard.Auth,
        AuroraMeter.LiveDashboard.NotStartedError,
        AuroraMeter.LiveDashboard.Sections,
        AuroraMeter.LiveDashboard.View,
        AuroraMeter.Migration.V1,
        AuroraMeter.Migration.V2,
        AuroraMeter.Migration.V3,
        AuroraMeter.Migration.V4,
        AuroraMeter.Migration.V5,
        AuroraMeter.Migration.V6,
        AuroraMeter.Migration.V7,
        AuroraMeter.Migration.V8,
        AuroraMeter.Migration.V9,
        AuroraMeter.Migration.V10,
        AuroraMeter.OpenTelemetry.Bridge,
        AuroraMeter.OpenTelemetry.Tracer,
        AuroraMeter.Plans.Snapshot,
        AuroraMeter.Schema.FlushReceipt,
        AuroraMeter.Storage.Ecto,
        AuroraMeter.Store,
        AuroraMeter.Subscriptions.Preview,
        AuroraMeter.Subscriptions.Transitions,
        AuroraMeter.Supervisor
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit, :mix],
      plt_local_path: "priv/plts"
    ]
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "dialyzer",
        "test",
        # --output, because a bare `mix docs` writes doc/ into the package tree
        # and .gitignore hides it from every porcelain-based tree check, so a
        # gate that asserts "this run changed nothing" cannot see it
        # (open-findings.md X21, X27). The gate is meant to leave the tree byte
        # identical; now it actually does.
        # --warnings-as-errors, because `mix docs` otherwise EXITS 0 on a broken
        # reference and this step then gates nothing: build unit 02a measured
        # `mix check` passing with 26 docs warnings (open-findings.md X82). A
        # criterion enforced by a human reading a log is not enforced. Verified
        # safe before it was added: both packages build docs with zero warnings
        # under this flag today.
        "docs --warnings-as-errors --output #{Path.join(System.tmp_dir!(), "aurora_meter-check-doc")}"
      ],
      # `check` keeps plain `test` so the local edit loop stays fast: cover
      # compiled modules run several times slower. CI runs `mix coverage` as its
      # own step on the pinned-tooling leg.
      coverage: ["test --cover"],
      # The two suites CI and scripts/v1/verify.sh both name. They are ALIASES on
      # purpose: package CI runs in the package repository and the V1 runners
      # live in the storefront, which package CI cannot check out, so the command
      # line is defined once here and both callers invoke it by name rather than
      # reimplementing it. Changing what a suite means is a change to this line.
      #
      # Neither tag is excluded in test/test_helper.exs, so both also run inside
      # the ordinary `mix test`. These jobs are a second, seeded run, not the
      # only run: a tagged suite that quietly stopped being included would
      # otherwise vanish from CI, and a skipped required suite is a failure.
      # test/aurora_meter/ci_contract_test.exs asserts exactly that.
      "v1.migrations": ["test --only migration"],
      "v1.faults": ["test --only fault --seed 0"],
      "test.setup": ["ecto.create --quiet", "ecto.migrate --quiet"]
    ]
  end
end
