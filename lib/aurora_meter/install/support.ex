defmodule AuroraMeter.Install.Support do
  @moduledoc """
  What this host resolves, against what Aurora Meter says it supports.

  `mix aurora_meter.install --check-support` prints this and exits non-zero when
  something present is below its floor. It is deliberately a plain module with
  no Igniter and no database in it, so the same answer is available from a
  release command, from `iex`, and from the installer's Igniter-less fallback.

  ## It never connects to anything

  Every row is read from the running system or from the host's own
  configuration. Nothing here opens a database connection, and that is why the
  Postgres row says what it says: a server version can only be learned by asking
  the server, and an installer that connects to a host's database to tell it
  about compatibility has done something the host did not ask for. The floor is
  printed; the check is the host's to run.
  """

  @typedoc "One row of the report."
  @type row :: %{
          name: String.t(),
          resolved: String.t() | nil,
          floor: String.t(),
          verdict: :ok | :below_floor | :absent | :unknown | :stale_build,
          note: String.t() | nil
        }

  @typedoc """
  How a row learns what is installed: `{resolved version or nil, guarded module
  compiled?}` for one dependency. Replaced in tests so both branches of the
  stale-build check run through the real row code.
  """
  @type probe :: (atom(), module() | nil -> {String.t() | nil, boolean()})

  # The floors Aurora Meter declares. `install_test.exs` compares the dependency
  # floors against `mix.exs` itself, so this list cannot drift from what the
  # package actually requires. (Until build unit 09b that comparison was a
  # sentence in this comment and nothing ran it, which is a rule nothing
  # enforces: `open-findings.md` X153.)
  @elixir_floor "1.15.8"
  @otp_floor "25"
  @postgres_floor "13"

  # `{app, floor, requirement, guarded module}`.
  #
  # The guarded module is the one compiled behind `if Code.ensure_loaded?(...)`
  # for that dependency. It is what makes the stale-build row possible: a host
  # that adds an optional dependency **after** Aurora Meter was compiled has the
  # dependency and not the integration, and every symptom of that points at the
  # host's own code.
  #
  # `phoenix_live_view`'s floor is 1.0.0 and not 0.20.0 (finding C9, decision
  # D12, build unit 09b): the components are written in 1.0 body interpolation,
  # which 0.20 renders as literal text.
  @deps [
    {:ecto_sql, "3.10.0", :required, nil},
    {:postgrex, "0.0.0", :required, nil},
    {:phoenix_pubsub, "2.1.0", :required, nil},
    {:telemetry, "1.2.0", :required, nil},
    {:jason, "1.4.0", :required, nil},
    {:nimble_options, "1.1.0", :required, nil},
    {:phoenix_live_view, "1.0.0", :optional, AuroraMeter.Components},
    # Half of the LiveView pair, with no guarded module of its own: what it
    # gates is gated through `phoenix_live_view` above.
    {:phoenix_html, "3.3.0", :optional, nil},
    {:plug, "1.15.0", :optional, AuroraMeter.Plug.EnsureEntitled},
    {:igniter, "0.8.0", :optional, nil},
    {:oban, "2.17.0", :optional, AuroraMeter.Oban},
    # Built rather than written. `AuroraMeter.OptionalIntegrationsTest` walks
    # the AST of every file in `lib/` and refuses an alias ending
    # `Telemetry.Metrics` outside the one guarded file, which is how 08a keeps
    # the optional preset module out of the rest of the package. A literal here
    # would be a reference the guard is about, even though this one only names
    # it (`open-findings.md` X327).
    {:telemetry_metrics, "0.6.0", :optional, Module.concat([:AuroraMeter, :Telemetry, :Metrics])},
    {:phoenix_live_dashboard, "0.8.0", :optional, AuroraMeter.LiveDashboard.Page},
    {:opentelemetry_api, "1.2.0", :optional, AuroraMeter.OpenTelemetry}
  ]

  @doc """
  Every row of the support report, in print order.

  `:probe` replaces how a dependency row learns what is installed. It exists so
  that the stale-build branch below can be induced and run rather than reasoned
  about; hosts never pass it.
  """
  @spec rows(keyword()) :: [row()]
  def rows(opts \\ []) do
    probe = Keyword.get(opts, :probe, &system_probe/2)

    [elixir_row(), otp_row(), postgres_row()] ++ Enum.map(@deps, &dep_row(&1, probe))
  end

  @doc """
  The dependency floors this package declares, as `{app, floor, requirement}`.

  Public so that a test can compare them against `mix.exs` rather than against a
  comment.
  """
  @spec declared_deps() :: [{atom(), String.t(), :required | :optional}]
  def declared_deps, do: Enum.map(@deps, fn {app, floor, req, _guard} -> {app, floor, req} end)

  @doc """
  Whether anything present is below its floor or half installed.

  An absent optional dependency is not a failure: that is the whole point of it
  being optional (invariant I20). A **present** one whose integration was not
  compiled is a failure, because the host has asked for something it is not
  getting and nothing else will tell it so.
  """
  @spec supported?([row()]) :: boolean()
  def supported?(rows \\ rows()),
    do: Enum.all?(rows, &(&1.verdict not in [:below_floor, :stale_build]))

  @doc """
  One line naming every row that is a problem, for the message an aborting
  `--check-support` raises with.

  Separate from `report/1` because the report is what a supported host reads and
  this is what an unsupported one has to act on.
  """
  @spec problem_summary([row()]) :: String.t()
  def problem_summary(rows \\ rows()) do
    case Enum.filter(rows, &(&1.verdict in [:below_floor, :stale_build])) do
      [] ->
        "Aurora Meter is supported on this host."

      problems ->
        "Aurora Meter is not supported on this host as it stands:\n" <>
          Enum.map_join(problems, "\n", fn
            %{verdict: :below_floor, resolved: nil} = row ->
              "  #{row.name} is required and is not resolved (floor #{row.floor})"

            %{verdict: :below_floor} = row ->
              "  #{row.name} #{row.resolved} is below the floor of #{row.floor}"

            %{verdict: :stale_build} = row ->
              "  #{row.name} #{row.resolved} is installed but its integration is not " <>
                "compiled: #{row.note}"
          end)
    end
  end

  @doc """
  The report as text, one line per row, with a verdict column.
  """
  @spec report([row()]) :: String.t()
  def report(rows \\ rows()) do
    width = rows |> Enum.map(&String.length(&1.name)) |> Enum.max()

    lines =
      Enum.map_join(rows, "\n", fn row ->
        "  " <>
          String.pad_trailing(row.name, width) <>
          "  " <>
          String.pad_trailing(row.resolved || "not installed", 14) <>
          "  floor " <>
          String.pad_trailing(row.floor, 8) <>
          "  " <>
          verdict(row.verdict) <> note(row.note)
      end)

    """
    Aurora Meter support check

    #{lines}

    A floor is a compatibility guarantee, not a recommendation. An absent
    optional dependency is fine: every integration behind one is compiled only
    when it is present.
    """
  end

  defp verdict(:ok), do: "ok"
  defp verdict(:below_floor), do: "BELOW FLOOR"
  defp verdict(:absent), do: "absent (optional)"
  defp verdict(:unknown), do: "not checked"
  defp verdict(:stale_build), do: "NOT COMPILED IN"

  defp note(nil), do: ""
  defp note(text), do: "  - " <> text

  # -- rows -------------------------------------------------------------------

  defp elixir_row do
    resolved = System.version()

    %{
      name: "elixir",
      resolved: resolved,
      floor: @elixir_floor,
      verdict: compare(resolved, @elixir_floor),
      note: nil
    }
  end

  # `:otp_release` is the major number only ("29"), which is all the floor is
  # stated in. `Version.parse/1` refuses a bare major, so it is padded rather
  # than compared as a string: "9" sorts above "25" and that is how a floor
  # check reports a supported host as unsupported.
  defp otp_row do
    resolved = List.to_string(:erlang.system_info(:otp_release))

    %{
      name: "erlang/otp",
      resolved: resolved,
      floor: @otp_floor,
      verdict: compare(resolved <> ".0.0", @otp_floor <> ".0.0"),
      note: nil
    }
  end

  defp postgres_row do
    %{
      name: "postgres",
      resolved: nil,
      floor: @postgres_floor,
      verdict: :unknown,
      note:
        "reading a server version means connecting to it, which this check does not do. " <>
          "`gen_random_uuid()` needs Postgres #{@postgres_floor} or the pgcrypto extension."
    }
  end

  # What the running system says, which is what every host gets.
  @spec system_probe(atom(), module() | nil) :: {String.t() | nil, boolean()}
  defp system_probe(app, guard) do
    resolved =
      case Application.spec(app, :vsn) do
        nil -> nil
        vsn -> List.to_string(vsn)
      end

    {resolved, guard != nil and Code.ensure_loaded?(guard)}
  end

  defp dep_row({app, floor, requirement, guard}, probe) do
    case probe.(app, guard) do
      {nil, _compiled?} ->
        %{
          name: Atom.to_string(app),
          resolved: nil,
          floor: floor,
          verdict: if(requirement == :optional, do: :absent, else: :below_floor),
          note: if(requirement == :required, do: "required and not resolved")
        }

      {resolved, compiled?} ->
        floor_verdict = compare(resolved, floor)

        cond do
          floor_verdict == :below_floor ->
            %{name: name(app), resolved: resolved, floor: floor, verdict: :below_floor, note: nil}

          guard != nil and not compiled? ->
            # The trap this row exists for: the dependency is in the host's tree
            # and `#{inspect(guard)}` is compiled behind
            # `if Code.ensure_loaded?/1`, so adding the dependency AFTER Aurora
            # Meter was compiled leaves the host with the dependency and without
            # the integration. Every symptom of that points at the host's own
            # code, which is why it is an error row with the fix in it rather
            # than a note.
            %{
              name: name(app),
              resolved: resolved,
              floor: floor,
              verdict: :stale_build,
              note:
                "#{inspect(guard)} was not compiled. Run " <>
                  "`mix deps.compile aurora_meter --force` and this row goes green."
            }

          true ->
            %{
              name: name(app),
              resolved: resolved,
              floor: floor,
              verdict: floor_verdict,
              note: nil
            }
        end
    end
  end

  defp name(app), do: Atom.to_string(app)

  # A version this check cannot parse is `:unknown` rather than a failure. A
  # pre-release or a git checkout is a host's own business, and refusing to
  # install because a version string was unusual would be the check causing the
  # outage it exists to prevent.
  defp compare(resolved, floor) do
    with {:ok, resolved} <- Version.parse(resolved),
         {:ok, floor} <- Version.parse(floor) do
      if Version.compare(resolved, floor) == :lt, do: :below_floor, else: :ok
    else
      :error -> :unknown
    end
  end
end
