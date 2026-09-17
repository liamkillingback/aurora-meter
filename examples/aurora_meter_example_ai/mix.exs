defmodule AuroraMeterExampleAi.MixProject do
  use Mix.Project

  def project do
    [
      app: :aurora_meter_example_ai,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # One project, two dependency resolutions, two lockfiles and two build
      # directories. See `pro?/0`.
      lockfile: lockfile(),
      build_path: build_path(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # ---------------------------------------------------------------------------
  # The Pro profile is opt in, and its default is off
  # ---------------------------------------------------------------------------
  #
  # `AURORA_SAMPLE_PRO=1` adds Aurora Meter Pro and the two dependencies it
  # needs. Anything else, including an unset variable, resolves a dependency
  # tree with no commercial package in it at all, which is the tree a reader
  # with no licence gets and the one this sample is written for.
  #
  # **Two resolutions means two lockfiles.** Without `:lockfile` a
  # `mix deps.get` with the flag set would rewrite `mix.lock` to mention
  # `aurora_meter_pro`, and the next core-profile run would resolve a lock
  # naming a package it cannot fetch. Both files are committed, so both
  # profiles are reproducible and CI can cache each.
  #
  # Verified on Mix 1.20.1 before it was relied on: with `lockfile:` set, only
  # the named file is written, and with it unset, only `mix.lock` is
  # (`docs/evidence/v1/phase-09/09d-pro-profile.md`).
  defp pro?, do: System.get_env("AURORA_SAMPLE_PRO") == "1"

  defp lockfile, do: if(pro?(), do: "mix.pro.lock", else: "mix.lock")

  # Two dependency resolutions need two build directories as well as two
  # lockfiles, and this line was added after the second one was not enough.
  #
  # With one `_build`, switching profiles leaves the other profile's compiled
  # artefacts in place: `deps/oban` is fetched for the Pro profile, the shared
  # `_build/test/lib/aurora_meter` was compiled while Oban was resolvable, and
  # a core-profile run then fails type checking on `Oban.Worker.backoff/1 is
  # undefined` inside a dependency it does not depend on. Observed here, not
  # reasoned about: the core suite went from green to "could not compile
  # dependency :aurora_meter" the first time it ran after a Pro-profile run.
  #
  # `deps/` is deliberately still shared. It holds fetched SOURCE, and a
  # package that is present but undeclared is not on the code path; the two
  # lockfiles keep the resolutions apart. It is `_build` that holds the answer
  # to "was this compiled with Oban present", and that answer is per profile.
  defp build_path, do: if(pro?(), do: "_build/pro", else: "_build/core")

  defp pro_deps do
    if pro?() do
      [
        pro_dep(),
        # Pro requires both. They are listed here rather than left transitive
        # so that a reader can see what the Pro profile adds to this
        # application's tree without reading Pro's mix.exs.
        {:oban, "~> 2.17"},
        {:stripity_stripe, "~> 3.2"}
      ]
    else
      []
    end
  end

  # The same shape Aurora Meter Pro uses for its own dependency on core
  # (`aurora_meter_pro/mix.exs`): a sibling checkout if there is one, the
  # private Hex package otherwise. In a customer's copy of this sample there is
  # no sibling, so the second branch is the one they take, and it is the branch
  # the README documents:
  #
  #     mix hex.organization auth phxtemplates --key "$AURORA_HEX_READ_KEY"
  #
  # run once, by the operator, with a read-only key from their own environment.
  # **No key is read by this file, and none is ever written into it.**
  defp pro_dep do
    path = Path.expand("../../../aurora_meter_pro", __DIR__)

    if File.dir?(path) and is_nil(System.get_env("AURORA_METER_PRO_FROM_HEX")) do
      {:aurora_meter_pro, path: path, override: true}
    else
      # `~> 1.0` and not `~> 0.3`: this sample is built against the 1.0 core and
      # Pro 1.0 requires it. `~> 0.3` would have resolved the published 0.3.0,
      # which declares core `~> 0.4` and does not compile against this tree
      # (`open-findings.md` X420, build unit 11c).
      {:aurora_meter_pro, "~> 1.0", organization: "phxtemplates"}
    end
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {AuroraMeterExampleAi.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.13"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # Aurora Meter, as a path dependency rather than a Hex requirement, so the
      # sample compiles against the working tree and a library change that
      # breaks it fails in the library's own CI on the same commit. Extracted to
      # its own repository this becomes `{:aurora_meter, "~> 1.0"}` and nothing
      # else changes.
      {:aurora_meter, path: "../.."},

      # Igniter is what `mix aurora_meter.install` runs on. It is a dev-time
      # tool: the running application never loads it.
      {:igniter, "~> 0.8", only: [:dev, :test], runtime: false}
    ] ++ pro_deps()
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create"] ++ migrate_steps("") ++ ["run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet"] ++ migrate_steps(" --quiet") ++ ["test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "tailwind aurora_meter_example_ai",
        "esbuild aurora_meter_example_ai"
      ],
      "assets.deploy": [
        "tailwind aurora_meter_example_ai --minify",
        "esbuild aurora_meter_example_ai --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  # Two migration paths, and the second one runs only in the Pro profile.
  #
  # `priv/repo/pro_migrations` holds the Oban tables and the Aurora Meter Pro
  # schema. Neither can live in `priv/repo/migrations`: Ecto compiles every
  # file in a path it is given, and neither `Oban.Migration` nor
  # `AuroraMeter.Pro.Migration` exists in a core-profile build, so a reader
  # without a licence would meet a missing dependency inside a migration.
  # Guarding the bodies instead would record the versions in
  # `schema_migrations` with none of the tables created, and the error would
  # then arrive at boot rather than at migration time.
  #
  # Both paths write into the same `schema_migrations`, keyed by version, so it
  # is one history in timestamp order.
  defp migrate_steps(flags) do
    core = ["ecto.migrate" <> flags]

    if pro?() do
      core ++ ["ecto.migrate --migrations-path priv/repo/pro_migrations" <> flags]
    else
      core
    end
  end
end
