defmodule Mix.Tasks.AuroraMeter.InstallTest do
  @moduledoc false
  # async: false — `Igniter.Test.test_project/1` puts the generated project's
  # config into the *global* application environment, so while this runs
  # `AuroraMeter.Config.repo/0` briefly answers `Demo.Repo`. Racing it against
  # an async test that touches the database fails that test, not this one.
  use ExUnit.Case, async: false

  import Igniter.Test

  test "wires config, supervision child, a plans module and the migration" do
    igniter =
      test_project(app_name: :demo)
      |> Igniter.compose_task("aurora_meter.install", ["--repo", "Demo.Repo"])

    # A fresh test project has no config.exs, so the installer creates it.
    assert_creates(igniter, "config/config.exs")

    config =
      igniter.rewrite |> Rewrite.source!("config/config.exs") |> Rewrite.Source.get(:content)

    assert config =~ "config :aurora_meter"
    assert config =~ "repo: Demo.Repo"
    assert config =~ "pubsub: Demo.PubSub"
    assert config =~ "plans: Demo.Plans"

    # Likewise the application module is created in a bare test project.
    assert_creates(igniter, "lib/demo/application.ex")

    application =
      igniter.rewrite
      |> Rewrite.source!("lib/demo/application.ex")
      |> Rewrite.Source.get(:content)

    assert application =~ "children = [AuroraMeter]"

    assert_creates(igniter, "lib/demo/plans.ex")

    plans =
      igniter.rewrite |> Rewrite.source!("lib/demo/plans.ex") |> Rewrite.Source.get(:content)

    assert plans =~ "use AuroraMeter.Plans"
    assert plans =~ "plan :free do"

    migration =
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.map(& &1.path)
      |> Enum.find(&String.match?(&1, ~r{priv/repo/migrations/\d+_add_aurora_meter\.exs}))

    assert migration, "expected a migration to be generated"

    body = igniter.rewrite |> Rewrite.source!(migration) |> Rewrite.Source.get(:content)
    assert body =~ "AuroraMeter.Migration.up()"
  end

  test "does not overwrite an existing plans module" do
    igniter =
      test_project(
        app_name: :demo,
        files: %{
          "lib/demo/plans.ex" => """
          defmodule Demo.Plans do
            use AuroraMeter.Plans

            plan :custom do
              price 0
            end
          end
          """
        }
      )
      |> Igniter.compose_task("aurora_meter.install", ["--repo", "Demo.Repo"])

    assert_unchanged(igniter, "lib/demo/plans.ex")
  end
end
