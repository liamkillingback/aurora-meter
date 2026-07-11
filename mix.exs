defmodule AuroraMeter.MixProject do
  use Mix.Project

  @version "0.0.1"
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
      "primitives for Phoenix — count, gate, and bill on the BEAM."
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Liam Killingback"],
      links: %{
        "GitHub" => @source_url,
        "PHXTemplates" => "https://phxtemplates.com"
      },
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md NOTICE.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE", "NOTICE.md"],
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
