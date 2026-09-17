defmodule AuroraMeter.Config.PrefixError do
  @moduledoc """
  Raised when a host asks Aurora Meter to live in a Postgres schema other than
  the repository's default one.

  V1 supports the default schema and nothing else. That is not a preference:
  every query this package issues omits the prefix, so a prefix that reached
  the migrations and not the queries would put the tables in one schema and
  read from another, and the first symptom would be an empty ledger rather
  than an error.

  There are three ways a host can ask for it and all three raise this, so the
  refusal happens before any table is created rather than after the first
  query comes back empty:

    * the repository sets `migration_default_prefix` (raised at boot by
      `AuroraMeter.Config.validate!/0`);
    * the repository's `default_options/1` returns a `:prefix` (same);
    * a migration runs under `mix ecto.migrate --prefix` (raised by
      `AuroraMeter.Migration.up/1` and `down/1` before any version runs).

  A fourth, `AuroraMeter.Migration.up(prefix: ...)`, raises `ArgumentError`,
  because an unknown option is an unknown option whatever it is called.

  `:source` says which of the three it was, so a host rescuing this needs one
  clause and can still tell the cases apart.
  """

  @type source ::
          {:repo_config, module(), atom(), term()}
          | {:default_options, module(), atom(), term()}
          | {:migration_runner, term()}

  @type t :: %__MODULE__{source: source(), message: String.t()}

  defexception [:source, :message]

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) do
    source = Keyword.fetch!(opts, :source)

    %__MODULE__{source: source, message: build_message(source)}
  end

  @spec build_message(source()) :: String.t()
  defp build_message({:repo_config, repo, key, value}) do
    "config :#{otp_app(repo)}, #{inspect(repo)}, #{key}: #{inspect(value)} would migrate " <>
      "Aurora Meter into the #{inspect(value)} schema, while every query this package " <>
      "issues reads the repository's default schema." <> remedy(key)
  end

  defp build_message({:default_options, repo, operation, value}) do
    "#{inspect(repo)}.default_options(#{inspect(operation)}) returns prefix: " <>
      "#{inspect(value)}, which would send every Aurora Meter query to the " <>
      "#{inspect(value)} schema, while its migrations create the tables in the " <>
      "repository's default schema. Stop returning a :prefix from " <>
      "#{inspect(repo)}.default_options/1, or give Aurora Meter a repository of its own " <>
      "that does not." <> support_sentence()
  end

  defp build_message({:migration_runner, prefix}) do
    "this migration is running with prefix #{inspect(prefix)} (from " <>
      "`mix ecto.migrate --prefix` or the repository's migration_default_prefix). " <>
      "Aurora Meter V1 creates its tables in the repository's default schema only: " <>
      "`create table` would honour the prefix, every `execute` in these versions and " <>
      "every runtime query would not, and the result is a database half in one schema " <>
      "and half in another. Nothing has been created; re-run without the prefix." <>
      support_sentence()
  end

  @spec remedy(atom()) :: String.t()
  defp remedy(key) when key != :default_options do
    " Remove #{inspect(key)} from the repository Aurora Meter is configured with, or " <>
      "give Aurora Meter a repository of its own that does not set it." <> support_sentence()
  end

  @spec support_sentence() :: String.t()
  defp support_sentence do
    " Aurora Meter V1 stores its tables in the repository's default schema; non-default " <>
      "Postgres schemas and multi-tenant schema prefixes are not supported."
  end

  @spec otp_app(module()) :: atom()
  defp otp_app(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
      Keyword.get(repo.config(), :otp_app, :my_app)
    else
      :my_app
    end
  rescue
    _ -> :my_app
  end
end
