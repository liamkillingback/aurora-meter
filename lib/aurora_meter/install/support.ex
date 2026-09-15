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
          verdict: :ok | :below_floor | :absent | :unknown,
          note: String.t() | nil
        }

  # The floors Aurora Meter declares. `aurora_meter_install_support_test.exs`
  # compares every one of them against `mix.exs` and the README table, so this
  # list cannot drift from what the package actually requires.
  @elixir_floor "1.15.8"
  @otp_floor "25"
  @postgres_floor "13"

  @deps [
    {:ecto_sql, "3.10.0", :required},
    {:postgrex, "0.0.0", :required},
    {:phoenix_pubsub, "2.1.0", :required},
    {:telemetry, "1.2.0", :required},
    {:jason, "1.4.0", :required},
    {:nimble_options, "1.1.0", :required},
    {:phoenix_live_view, "0.20.0", :optional},
    {:igniter, "0.8.0", :optional},
    {:oban, "2.17.0", :optional}
  ]

  @doc """
  Every row of the support report, in print order.
  """
  @spec rows() :: [row()]
  def rows do
    [elixir_row(), otp_row(), postgres_row()] ++ Enum.map(@deps, &dep_row/1)
  end

  @doc """
  Whether anything present is below its floor.

  An absent optional dependency is not a failure: that is the whole point of it
  being optional (invariant I20).
  """
  @spec supported?([row()]) :: boolean()
  def supported?(rows \\ rows()), do: Enum.all?(rows, &(&1.verdict != :below_floor))

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

  defp dep_row({app, floor, requirement}) do
    case Application.spec(app, :vsn) do
      nil ->
        %{
          name: Atom.to_string(app),
          resolved: nil,
          floor: floor,
          verdict: if(requirement == :optional, do: :absent, else: :below_floor),
          note: if(requirement == :required, do: "required and not resolved")
        }

      vsn ->
        resolved = List.to_string(vsn)

        %{
          name: Atom.to_string(app),
          resolved: resolved,
          floor: floor,
          verdict: compare(resolved, floor),
          note: nil
        }
    end
  end

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
