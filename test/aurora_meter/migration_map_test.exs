defmodule AuroraMeter.MigrationMapTest do
  @moduledoc """
  The binding map's list of destructive versions against this package's list.

  `docs/v1/build-plans/schema-migration-map.md` section 3 names the versions
  whose `down` destroys a commercial fact. `AuroraMeter.Migration` names them
  too. For five phases those were two lists and **nothing compared them**: the
  map said core 1, 3, 4, 7, 8, 9, 10 and the code said 7, 9, 10, so a host that
  generated an upgrade covering version 1, 3, 4 or 8 got a `down` with no
  confirmation on it (`open-findings.md` X362). Pro had no list at all and the
  map names six versions for it (X369).

  The transferable point, and the reason this module is three tests rather than
  one assertion: a list in a binding document and a list in code are two lists,
  and a programme that writes both and compares neither will keep discovering
  the difference by accident. The chain checked here is

      binding map  ->  the quotation below  ->  data_loss_versions/0

  and both links are asserted. The quotation is a literal so that this test runs
  in a standalone clone of the package, where the map is not on disk; the second
  test proves the quotation is still what the map says, and refuses to go quiet
  unless the map is genuinely absent because the whole storefront is.
  """
  use ExUnit.Case, async: true

  @moduletag :migration

  alias AuroraMeter.Migration

  # Quoted verbatim from `schema-migration-map.md` section 3, 2026-09-17.
  @map_sentence "The complete list is core 1, 3, 4, 7, 8, 9, 10 and Pro 1, 2, 8, 9, 10, 11."

  # The package root is `<storefront>/product-workspaces/aurora_meter` in the
  # development monorepo, and anywhere at all in a standalone clone.
  @storefront Path.expand("../..", File.cwd!())
  @map Path.join(@storefront, "docs/v1/build-plans/schema-migration-map.md")

  test "I19 X362 every version the binding map calls destructive is in data_loss_versions/0" do
    {core, _pro} = parse!(@map_sentence)

    assert Migration.data_loss_versions() == core,
           "the binding map names core #{inspect(core)} and this package names " <>
             "#{inspect(Migration.data_loss_versions())}. A version missing here generates " <>
             "a host `down` with no confirm_data_loss on it, which is finding X362."
  end

  test "I19 X362 the quotation above is still what the binding map says" do
    if File.exists?(@map) do
      map = File.read!(@map)

      assert map =~ @map_sentence,
             "schema-migration-map.md section 3 no longer contains the sentence this test " <>
               "quotes. Re-read the map and update @map_sentence, then check both packages' " <>
               "data_loss_versions/0 against the new list."
    else
      # Not a skip. The map is only legitimately absent when the package has
      # been cloned on its own, which is how its CI runs. If the storefront is
      # there and the map is not, the map has been moved or deleted and this
      # test is the thing that should notice.
      refute File.exists?(Path.join(@storefront, "mix.exs")),
             "the storefront is at #{@storefront} but its binding map is not at #{@map}. " <>
               "The map has moved; this comparison is now checking nothing."
    end
  end

  test "I19 X362 every listed version is given a reason, and no unlisted version is" do
    reasons = Migration.data_loss_reasons()

    assert reasons |> Map.keys() |> Enum.sort() == Migration.data_loss_versions()

    for {version, reason} <- reasons do
      assert is_binary(reason) and String.length(reason) > 40,
             "version #{version} is refused with no reason a reader could act on"
    end

    # The refusal must name the version asked for. Before X362 the message
    # described version 7 whatever version was passed, which is how a wrong list
    # stays invisible: the text read plausibly for every version on it.
    error =
      assert_raise Migration.DataLossError, fn ->
        Migration.down(version: 8, to: 8)
      end

    assert error.destructive == [8]
    assert error.package == "Aurora Meter"
    assert error.message =~ "Version 8"
    assert error.message =~ "identity guarantee"
    refute error.message =~ "Version 7", "the message is about the version that was asked for"
  end

  defp parse!(sentence) do
    [_, core, pro] =
      Regex.run(~r/core ((?:\d+, )*\d+) and Pro ((?:\d+, )*\d+)/, sentence)

    {numbers(core), numbers(pro)}
  end

  defp numbers(list) do
    list |> String.split(", ") |> Enum.map(&String.to_integer/1) |> Enum.sort()
  end
end
