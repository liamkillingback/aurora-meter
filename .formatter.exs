locals_without_parens = [
  plan: 2,
  price: 1,
  limit: 3,
  metered: 2,
  counter: 1,
  feature: 2,
  recurring_credits: 2
]

# `import_deps` names dependencies, and `mix format` RAISES when one of them is
# not in the dependency tree for the current environment. The AURORA_ build
# switches take `phoenix_live_view` out (`AURORA_HEADLESS` removes every optional
# dependency, `AURORA_NO_LIVEVIEW` removes the LiveView pair and the dashboard),
# so naming it unconditionally makes every formatter read on those legs raise.
#
# That is not only `mix format`: Sourceror reads the project's formatter
# configuration on its way to printing an edit, so `mix aurora_meter.install`
# raised `Unknown dependency :phoenix_live_view given to :import_deps` on the
# `plug_only` leg and took thirty of its tests with it. Found by that leg, which
# is the first build in this repository to have Igniter present and LiveView
# absent (build units 09a and 09b).
#
# The general shape is X331's: a leg that removes a dependency has to remove
# every claim that depends on it, and a claim in a configuration file is as real
# as one in `mix.exs`.
# The plugin is the same claim in the same file: `Phoenix.LiveView.HTMLFormatter`
# only exists when LiveView does, and a plugin the formatter cannot load fails
# the same way the import does.
without_live_view? =
  System.get_env("AURORA_HEADLESS") == "1" or System.get_env("AURORA_NO_LIVEVIEW") == "1"

import_deps =
  if without_live_view?, do: [:ecto, :ecto_sql], else: [:ecto, :ecto_sql, :phoenix_live_view]

plugins = if without_live_view?, do: [], else: [Phoenix.LiveView.HTMLFormatter]

[
  import_deps: import_deps,
  plugins: plugins,
  inputs: ["*.{ex,exs}", "{config,lib,test,priv}/**/*.{ex,exs,heex}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
