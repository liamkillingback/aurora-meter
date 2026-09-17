defmodule AuroraMeterExampleAi.Pro.Children do
  @moduledoc """
  The supervision children the Pro profile adds, and an empty list otherwise.

  This is the one module in the Pro tree whose **name** has to exist in both
  profiles, because `AuroraMeterExampleAi.Application` calls it
  unconditionally. So the guard is around the function bodies rather than
  around the whole module:

      if Code.ensure_loaded?(AuroraMeter.Pro) do
        def list, do: [ ... ]
      else
        def list, do: []
      end

  The alternative shape, guarding the whole module and reaching it with
  `apply/3` from `application.ex`, works too and is what the sample would need
  if this module had to name Pro in its own signature. It is worth knowing
  which problem each shape solves, because getting it wrong is how a free core
  ends up emitting `AuroraMeter.Oban.cron_entries/0 is undefined` on every
  compile in a host that has no Oban, which is a real defect this project
  found and fixed (`open-findings.md` X378).

  ## Order

  Oban before `AuroraMeter.Pro`, and `AuroraMeter.Pro` after the Repo, because
  its boot checks read two Pro tables and can only warn when the repo is not up
  yet. Its own documentation says so and this is the host obeying it rather
  than discovering it.
  """

  if Code.ensure_loaded?(AuroraMeter.Pro) do
    @doc """
    Oban and the Pro boot checks, in that order.

    `AuroraMeter.Pro` starts no process: `start_link/1` runs the checks and
    returns `:ignore`, which with `restart: :transient` is a clean start a
    supervisor accepts and never restarts.
    """
    @spec list() :: [Supervisor.child_spec() | {module(), term()} | module()]
    def list do
      [
        {Oban, Application.fetch_env!(:aurora_meter_example_ai, Oban)},
        AuroraMeter.Pro
      ]
    end

    @doc "True in this build."
    @spec enabled?() :: boolean()
    def enabled?, do: true
  else
    @doc """
    An empty list. The core profile starts no Oban, no Pro boot check and no
    Stripe anything, because none of them is in the build.
    """
    @spec list() :: []
    def list, do: []

    @doc "False in this build."
    @spec enabled?() :: boolean()
    def enabled?, do: false
  end
end
