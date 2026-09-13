defmodule AuroraMeter.MixProject do
  use Mix.Project

  @version "0.4.0"
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
      aliases: aliases(),
      name: "Aurora Meter",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      dialyzer: dialyzer(),
      test_coverage: [summary: [threshold: 0]]
    ]
  end

  def cli do
    [preferred_envs: [check: :test, "test.setup": :test]]
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
  defp deps do
    [
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.2"},
      {:nimble_options, "~> 1.1"},
      {:jason, "~> 1.4"},
      {:phoenix_live_view, "~> 0.20 or ~> 1.0", optional: true},
      {:phoenix_html, "~> 3.3 or ~> 4.0", optional: true},
      # Optional: powers the one-step `mix aurora_meter.install`. Hosts without
      # it get the print-the-steps fallback.
      {:igniter, "~> 0.8", optional: true},

      # Dev/test tooling — never shipped to consumers. ex_doc and dialyxir are
      # available in :test too so the `check` alias (which runs in :test) can
      # build docs and run dialyzer in one pass.
      {:ex_doc, "~> 0.31", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:floki, ">= 0.30.0", only: :test}
    ]
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
        "docs/examples/concepts.md",
        "docs/examples/team-saas.md",
        "docs/examples/allowance-and-overage.md",
        "docs/examples/prepaid-credits.md",
        "docs/examples/showing-usage.md",
        "docs/configuration.md",
        "docs/metering.md",
        "docs/entitlements.md",
        "docs/plans.md",
        "docs/credits.md",
        "docs/telemetry.md",
        "docs/testing.md",
        "docs/clustering.md",
        "docs/adr/0001-resolved-decisions.md",
        "docs/adr/0002-ets-counter-substrate.md",
        "docs/adr/0003-buffered-vs-durable-and-period-seam.md",
        "docs/adr/0004-cluster-wide-counters.md",
        "docs/adr/0005-prepaid-credit-ledger.md",
        "docs/adr/0006-counter-feature-kind.md",
        "docs/adr/0007-idempotent-flush-batches.md",
        "docs/adr/0008-pending-quota-work.md"
      ],
      groups_for_extras: [
        Examples: ~r/docs\/examples\//,
        Guides: ~r/docs\/[^\/]+$/,
        ADRs: ~r/docs\/adr\//
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      formatters: ["html"]
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
        "docs"
      ],
      "test.setup": ["ecto.create --quiet", "ecto.migrate --quiet"]
    ]
  end
end
