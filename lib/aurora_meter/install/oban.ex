if Code.ensure_loaded?(Igniter) do
  defmodule AuroraMeter.Install.Oban do
    @moduledoc """
    Adds Aurora Meter's crontab entries to a host's Oban configuration, and
    nothing else.

    Compiled only when Igniter is installed, like the installer task that calls
    it. Public because **Aurora Meter Pro's installer calls it too**: the merge
    is fiddly (Sourceror wraps every literal, and a list appended to twice is a
    list with two Cron plugins in it), and one implementation with one set of
    tests is better than the same hundred lines copied across a package
    boundary and then drifting.

    ## The rule, and it is the whole module

    **It adds and it never replaces.** A queue concurrency the host chose, a
    schedule the host chose for one of these workers, the order of the plugins
    list and every other plugin option all survive untouched. An entry is
    "already there" when some entry names the same worker module, **whatever its
    schedule**, so a host that decided the expiry sweep should run at four in
    the morning keeps that and gains no second entry beside it.

    That is what makes a second run of either installer a no-op, which is the
    G05 bullet both of them owe.
    """

    alias AuroraMeter.Install.Templates
    alias Igniter.Code.Common
    alias Igniter.Code.Function
    alias Igniter.Code.Keyword, as: CodeKeyword
    alias Igniter.Code.List, as: CodeList
    alias Igniter.Project.Application, as: IgniterApp
    alias Igniter.Project.Config, as: IgniterConfig
    alias Igniter.Project.Module, as: IgniterModule
    alias Sourceror.Zipper

    @doc """
    Wires `entries` into the host's `config :<otp_app>, Oban`.

    Options:

      * `:otp_app` (required) - the host application whose configuration this is.
      * `:repo` (required) - the repo to write when the Oban configuration does
        not exist yet. An existing `:repo` is never changed.
      * `:entries` (required) - `[{schedule, worker}]`, from
        `AuroraMeter.Oban.cron_entries/1` or `AuroraMeter.Pro.cron_entries/1`.
    """
    @spec wire(Igniter.t(), keyword()) :: Igniter.t()
    def wire(igniter, opts) do
      otp_app = Keyword.fetch!(opts, :otp_app)
      repo = Keyword.fetch!(opts, :repo)
      entries = Keyword.fetch!(opts, :entries)

      IgniterConfig.configure(
        igniter,
        "config.exs",
        otp_app,
        [Oban],
        {:code, code(Templates.oban_config(repo, entries))},
        updater: &{:ok, merge(&1, repo, entries)}
      )
    end

    @doc """
    Adds the `AuroraMeter.Oban.validate!/1` line to the host's
    `Application.start/2`, once.

    It reads configuration rather than a running Oban instance, so it is correct
    wherever the host puts the Oban child relative to `AuroraMeter`, and a
    second run finds it and adds nothing.
    """
    @spec validate_call(Igniter.t(), atom()) :: Igniter.t()
    def validate_call(igniter, otp_app) do
      line = Templates.validate_call(otp_app)

      case IgniterApp.app_module(igniter) do
        nil ->
          Igniter.add_notice(igniter, Templates.validate_manual(otp_app))

        module ->
          module = with {module, _rest} <- module, do: module

          IgniterModule.find_and_update_module!(igniter, module, &add_validate(&1, line))
      end
    end

    defp add_validate(zipper, line) do
      with {:ok, zipper} <- Function.move_to_def(zipper, :start, 2) do
        if contains_validate?(zipper),
          do: {:ok, zipper},
          else: {:ok, Common.add_code(zipper, line, placement: :before)}
      end
    end

    @doc """
    The workers a host's crontab already names, as module-name strings.

    Read by Aurora Meter Pro's installer to refuse a crontab that would schedule
    both expiry workers. Strings rather than atoms, because core must not
    reference a Pro module and this is a name a host wrote in its own file.
    """
    @spec scheduled_workers(Igniter.t(), atom()) :: [String.t()]
    def scheduled_workers(igniter, otp_app) do
      igniter
      |> IgniterConfig.configures_key?("config.exs", otp_app, [Oban])
      |> if do
        source(igniter, "config/config.exs")
      else
        ""
      end
      |> then(&Regex.scan(~r/\{\s*"[^"]*"\s*,\s*([A-Z][A-Za-z0-9_.]*)\s*\}/, &1))
      |> Enum.map(fn [_whole, worker] -> worker end)
      |> Enum.uniq()
    end

    defp source(igniter, path) do
      case Rewrite.source(igniter.rewrite, path) do
        {:ok, source} -> Rewrite.Source.get(source, :content)
        _absent -> ""
      end
    end

    # A textual check, and deliberately so. The line may have been written by an
    # earlier run of an installer, by the host by hand, or with a different
    # `:otp_app` spelling, and all three mean "the call is here". Matching the
    # AST exactly would add the line a second time for the second and third.
    defp contains_validate?(zipper) do
      zipper
      |> Zipper.topmost()
      |> Zipper.node()
      |> Sourceror.to_string()
      |> String.contains?("AuroraMeter.Oban.validate!")
    end

    # -- the merge ------------------------------------------------------------

    # Every branch below adds and none replaces. `set_keyword_key/4`'s updater
    # is `&{:ok, &1}` wherever a host may already have an opinion, which is
    # Igniter's way of spelling "leave what is there".
    defp merge(zipper, repo, entries) do
      zipper
      |> keyword(:repo, code(inspect(repo)))
      |> keyword(:queues, code("[aurora_meter: 5]"), &queues/1)
      |> keyword(
        :plugins,
        code("[" <> Templates.cron_plugin(entries) <> "]"),
        &plugins(&1, entries)
      )
    end

    defp keyword(zipper, key, value, updater \\ &{:ok, &1}) do
      case CodeKeyword.set_keyword_key(zipper, key, value, updater) do
        {:ok, zipper} -> zipper
        :error -> zipper
      end
    end

    # The queue is added only when absent, so a concurrency the host chose is
    # never changed. `&{:ok, &1}` is the whole of that promise.
    #
    # `Templates.queue/0` and not `AuroraMeter.Oban.queue/0`: this module is
    # compiled whenever Igniter is present and `AuroraMeter.Oban` only when Oban
    # is, so the direct call was a compile-time reference to a module a host
    # without Oban does not have. It warned on every compile of the dependency in
    # such a host, which is the first thing a new host saw (X375, repair unit
    # R5). The two values are asserted equal by the package's own suite.
    defp queues(zipper) do
      CodeKeyword.set_keyword_key(zipper, Templates.queue(), 5, &{:ok, &1})
    end

    # `Igniter.Code.Common.within/2` because `set_keyword_key/4` re-wraps
    # whatever node its updater returns as the key's value: an updater that
    # hands back a zipper from deeper in the tree replaces the whole list with
    # that one node. `within/2` runs the edit and comes back up to where it
    # started, which is the contract the caller needs.
    defp plugins(zipper, entries) do
      Common.within(zipper, fn list ->
        case CodeList.move_to_list_item(list, &cron_plugin?/1) do
          {:ok, plugin} -> merge_cron(plugin, entries)
          :error -> CodeList.append_to_list(list, cron_plugin(entries))
        end
      end)
    end

    # A host may have written the plugin either way round. `Oban.Plugins.Cron`
    # on its own is a Cron plugin with no crontab, and giving it one is adding
    # rather than changing, so it is upgraded to the tuple form. In the tuple
    # form every option the host set is kept and only `:crontab` is touched.
    defp merge_cron(plugin, entries) do
      case unwrap(Zipper.node(plugin)) do
        {:__aliases__, _meta, _parts} ->
          {:ok, Zipper.replace(plugin, cron_plugin(entries))}

        {_module, _opts} ->
          Common.within(plugin, &crontab_of(&1, entries))

        _other ->
          {:ok, plugin}
      end
    end

    # The zipper of the `{Oban.Plugins.Cron, opts}` tuple's second element, where
    # the plugin's options live, with only `:crontab` touched.
    defp crontab_of(tuple, entries) do
      tuple
      |> Common.maybe_move_to_single_child_block()
      |> Zipper.down()
      |> Zipper.right()
      |> CodeKeyword.set_keyword_key(
        :crontab,
        code(Templates.crontab(entries)),
        &append_missing(&1, entries)
      )
    end

    # An entry is "already there" when an entry names the same worker, whatever
    # its schedule.
    defp append_missing(zipper, entries) do
      Common.within(zipper, fn list -> {:ok, Enum.reduce(entries, list, &append_one/2)} end)
    end

    defp append_one(entry, list) do
      case CodeList.append_new_to_list(list, entry_ast(entry), &same_worker?/2) do
        {:ok, list} -> list
        :error -> list
      end
    end

    defp same_worker?(a, b), do: worker_of(a) != nil and worker_of(a) == worker_of(b)

    defp worker_of(%Zipper{} = zipper), do: zipper |> Zipper.node() |> worker_of()

    defp worker_of(node) do
      case unwrap(node) do
        {_schedule, worker} -> Sourceror.to_string(worker)
        {:{}, _meta, [_schedule, worker | _rest]} -> Sourceror.to_string(worker)
        _other -> nil
      end
    end

    defp cron_plugin?(zipper) do
      case unwrap(Zipper.node(zipper)) do
        {:__aliases__, _meta, parts} -> List.last(parts) == :Cron
        {module, _opts} -> alias_named?(unwrap(module), :Cron)
        {:{}, _meta, [module | _rest]} -> alias_named?(unwrap(module), :Cron)
        _other -> false
      end
    end

    defp alias_named?({:__aliases__, _meta, parts}, name), do: List.last(parts) == name
    defp alias_named?(_other, _name), do: false

    # Sourceror keeps a literal's formatting by wrapping it in a one-child
    # `:__block__`, so every list item, every tuple element and every keyword
    # value arrives wrapped. A predicate that matches the bare shape therefore
    # never fires, which is how the first draft of this appended a second
    # `Oban.Plugins.Cron` plugin on every run instead of finding the one that
    # was already there. Measured, not reasoned about.
    defp unwrap({:__block__, _meta, [single]}), do: single
    defp unwrap(other), do: other

    defp code(source), do: Sourceror.parse_string!(source)

    defp cron_plugin(entries), do: code(Templates.cron_plugin(entries))

    defp entry_ast({schedule, worker}),
      do: code("{#{inspect(schedule)}, #{inspect(worker)}}")
  end
end
