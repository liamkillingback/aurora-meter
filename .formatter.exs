locals_without_parens = [
  plan: 2,
  price: 1,
  limit: 3,
  metered: 2,
  counter: 1,
  feature: 2,
  recurring_credits: 2
]

[
  import_deps: [:ecto, :ecto_sql, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{ex,exs}", "{config,lib,test,priv}/**/*.{ex,exs,heex}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
