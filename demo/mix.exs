defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [mod: {Demo.Application, []}, extra_applications: [:logger]]
  end

  # Depends on Aurora Meter by path — this app exists to prove the install story.
  defp deps do
    [{:aurora_meter, path: ".."}]
  end
end
