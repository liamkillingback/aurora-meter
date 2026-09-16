defmodule AuroraMeter.Install.Options do
  @moduledoc false
  # **Internal.** Parsing and validating the two installer switches that write a
  # policy decision into a host's configuration.
  #
  # It lives outside the Igniter guard on purpose. `mix aurora_meter.install`
  # has two definitions, one for a host with Igniter and one without, and both
  # have to understand the same switches: the Igniter one writes the keys and
  # the fallback one prints them. A parser inside the guard would have left the
  # fallback silently ignoring a switch the operator passed, which is the worst
  # of the three possible behaviours.
  #
  # Every refusal here happens before the caller writes anything at all.

  @policies [:allow, :warn, :deny, :raise]
  @sources [:buffered, :events]

  # A feature name the host could have written in its plans module. Checked with
  # a pattern rather than `String.to_existing_atom/1`, because the installer runs
  # before the plans module exists and no feature atom is loaded yet; and not
  # with a bare `String.to_atom/1`, because that turns a command line typo into a
  # permanent entry in the atom table.
  @feature_name ~r/^[a-z][a-zA-Z0-9_]*$/

  @typedoc "What the installer will write."
  @type t :: %{
          policy: :allow | :warn | :deny | :raise,
          feature_sources: %{atom() => :buffered | :events}
        }

  @doc """
  Parses `--feature-policy` and `--events-source`.

  Returns `{:ok, settings}` or `{:error, message}`. The message is written for
  the operator reading it in a terminal: it names what was wrong, what the valid
  values are, and says that nothing was written.
  """
  @spec parse(keyword()) :: {:ok, t()} | {:error, String.t()}
  def parse(opts) do
    with {:ok, policy} <- policy(opts[:feature_policy]),
         {:ok, sources} <- sources(List.wrap(opts[:events_source])) do
      {:ok, %{policy: policy, feature_sources: sources}}
    end
  end

  @doc "The default policy a fresh V1 install is given (decision D04)."
  @spec default_policy() :: :deny
  def default_policy, do: :deny

  # -- --feature-policy -------------------------------------------------------

  # Decision D04: a new install denies a feature no plan declares. It is written
  # explicitly rather than left to the library default, so a host's own file
  # records the choice and a later release changing its default cannot change
  # what an installed host does.
  defp policy(nil), do: {:ok, default_policy()}

  defp policy(value) when is_binary(value) do
    if value in Enum.map(@policies, &Atom.to_string/1) do
      {:ok, String.to_existing_atom(value)}
    else
      {:error,
       "--feature-policy #{value} is not one of #{values(@policies)}.\n\n" <>
         "  deny   refuse a feature no plan declares (the default for a new install)\n" <>
         "  raise  the same, as an exception rather than a refusal\n" <>
         "  warn   allow it and log, which is the upgrade path for an existing install\n" <>
         "  allow  allow it silently, which is how Aurora Meter behaved before 1.0\n\n" <>
         "Nothing was written."}
    end
  end

  # -- --events-source --------------------------------------------------------

  defp sources(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      case source(entry, acc) do
        {:ok, {feature, source}} -> {:cont, {:ok, Map.put(acc, feature, source)}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp source(entry, acc) do
    case String.split(entry, ":", parts: 2) do
      [feature, source] -> pair(entry, String.trim(feature), String.trim(source), acc)
      _one_part -> {:error, malformed(entry)}
    end
  end

  defp pair(entry, feature, source, acc) do
    cond do
      not Regex.match?(@feature_name, feature) ->
        {:error,
         "--events-source #{entry} names #{inspect(feature)}, which is not a feature name.\n" <>
           "A feature is an atom written the way you write it in your plans module: " <>
           "lower case, starting with a letter, letters digits and underscores after that.\n\n" <>
           "Nothing was written."}

      source not in Enum.map(@sources, &Atom.to_string/1) ->
        {:error,
         "--events-source #{entry} names source #{inspect(source)}, which is not one of " <>
           "#{values(@sources)}.\n\n" <>
           "  buffered  counted in memory and flushed in batches (the default)\n" <>
           "  events    recorded durably one event at a time, then projected\n\n" <>
           "A feature has exactly one reporting source. Nothing was written."}

      Map.has_key?(acc, String.to_atom(feature)) ->
        {:error,
         "--events-source names #{feature} twice. A feature has exactly one " <>
           "reporting source, so there is no answer to give here.\n\nNothing was written."}

      true ->
        {:ok, {String.to_atom(feature), String.to_existing_atom(source)}}
    end
  end

  defp malformed(entry) do
    "--events-source #{entry} is not `feature:source`. Write it as, for example, " <>
      "`--events-source tokens:events`, once per feature.\n\nNothing was written."
  end

  defp values(atoms), do: Enum.map_join(atoms, ", ", &Atom.to_string/1)
end
