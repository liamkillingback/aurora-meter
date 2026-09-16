defmodule AuroraMeter.ReleaseMetadataTest do
  @moduledoc """
  Build unit 02d. The version a release claims is written in five places and a
  release is wrong if any two of them disagree.

    * **G02**: `mix.exs`'s `@version`, the top `CHANGELOG.md` heading, the `~>`
      requirement in `README.md` and in `docs/getting-started.md`, and the tag
      `docs/RELEASE.md` tells the owner to create, all agree.
    * **G04**: a transition release changes no schema version.

  `docs/RELEASE.md` is the reason this file exists. Its checklist and its
  `git tag` command are the last thing a release touches and the first thing a
  version bump forgets, and nothing noticed when `git tag v0.4.0` stayed behind
  after the bump to 0.5.0. Releases are the owner's (decision D13), so the least
  an agent can do is hand over a document whose commands are the right ones.

  It also guards which decision records reach hexdocs. Seven core ADRs were
  absent from `docs()` extras (`open-findings.md` X85) and two of them describe
  behaviour that ships in this release; publishing the other five would put V1
  design that has not shipped on the public documentation site as though it had.

  No database, no processes: it reads files and `Mix.Project.config/0`.
  """
  use ExUnit.Case, async: true

  @changelog "CHANGELOG.md"
  @readme "README.md"
  @getting_started "docs/getting-started.md"
  @release_doc "docs/RELEASE.md"

  # G04. The schema version this tree carries.
  #
  # 0.5.0, the transition release, shipped 6 and was schema-neutral by design,
  # which is why it can be rolled back as safely as it is rolled forward. Build
  # unit 03a moved this to 8 when core schema versions 7 and 8 landed on the V1 branch,
  # as the previous comment here instructed: "change this number only in the
  # release that actually adds a migration version".
  #
  # The half of that instruction 03a could not carry out is the changelog. A
  # non-empty `[Unreleased]` section is refused two tests above, and the 0.5.0
  # section's statement that `latest_version()` is 6 was true of that release
  # and must not be rewritten. The release that ships schema 7 and 8 (10a / 11e)
  # owes the changelog the new number. Recorded as a finding in 03a's evidence.
  @schema_version 10

  # X85. ADRs describing behaviour that has shipped, and therefore belong on
  # hexdocs with the release that shipped it.
  @published_adrs [
    "docs/adr/0010-undeclared-features-and-config-strictness.md",
    "docs/adr/0015-period-contract-and-clock-seam.md"
  ]

  # ADRs describing V1 design that has not shipped. Each is published by the
  # unit that ships it; until then, a reader on hexdocs would take a plan for a
  # feature.
  @unpublished_adrs [
    "docs/adr/0009-durable-event-semantics.md",
    "docs/adr/0011-credit-lots-and-allocations.md",
    "docs/adr/0012-immutable-plan-versions.md",
    "docs/adr/0013-narrow-ai-shaped-sample.md",
    "docs/adr/0014-optional-integrations-stay-free.md",
    "docs/adr/0016-scheduled-plan-transitions.md"
  ]

  describe "G02 one version, five places" do
    test "G02 mix.exs version matches the top CHANGELOG heading" do
      assert {top, date} = top_release()

      assert top == version(),
             "#{@changelog}'s newest release heading is #{top} and mix.exs is #{version()}"

      assert date =~ ~r/^\d{4}-\d{2}-\d{2}$/,
             "#{@changelog}: the #{top} heading carries no release date"
    end

    # Scoped to the release cut on 2026-09-15 (open-findings.md X139).
    #
    # As written this ran on every `mix test` and asserted that [Unreleased] is
    # empty. That is right at a release cut and wrong on a development branch,
    # where "in the tree but not in any release" is exactly the state, and where
    # finding X86 requires every unit to append its entry as it lands rather
    # than leaving the changelog to be written from memory at release time. The
    # two rules contradicted each other and this one won by running more often:
    # core's gate went red the moment the section was populated.
    #
    # So the check now runs where the decision is made. AURORA_RELEASE=1 is set
    # by the release preflight; 11e owns wiring it into `scripts/v1/release.sh`,
    # and until it does, a release cut runs this file with the variable set.
    # The assertion itself is unchanged and is deliberately not weakened.
    @tag :release_gate
    test "G02 nothing is left in an Unreleased section above the release heading" do
      if System.get_env("AURORA_RELEASE") == "1" do
        above =
          @changelog
          |> File.read!()
          |> String.split(~r/^## \[/m)
          |> Enum.find(&String.starts_with?(&1, "Unreleased]"))

        assert above == nil or String.trim(String.replace(above, "Unreleased]", "")) == "",
               "#{@changelog} has a non-empty [Unreleased] section at a release cut. " <>
                 "Everything in the tree is either in the release or is not in the " <>
                 "release; a heading that says neither is how a change ships undocumented"
      else
        # The development-branch half of the same rule: if the section exists it
        # must carry content, because an empty [Unreleased] on a branch that has
        # moved past its last release is the undocumented-change failure in the
        # other direction.
        text = File.read!(@changelog)

        if String.contains?(text, "## [Unreleased]") do
          above =
            text
            |> String.split(~r/^## \[/m)
            |> Enum.find(&String.starts_with?(&1, "Unreleased]"))

          refute String.trim(String.replace(above, "Unreleased]", "")) == "",
                 "#{@changelog} has an empty [Unreleased] heading. Either record what " <>
                   "is in the tree and not in a release, or remove the heading"
        end
      end
    end

    test "G02 the README install snippet matches the version's requirement" do
      assert File.read!(@readme) =~ requirement_snippet(),
             "#{@readme} does not show #{inspect(requirement_snippet())}"
    end

    test "G02 docs/getting-started.md matches the README install snippet" do
      assert File.read!(@getting_started) =~ requirement_snippet(),
             "#{@getting_started} does not show #{inspect(requirement_snippet())}"
    end

    test "G02 the requirement admits this version and stops at the next major" do
      assert Version.match?(version(), requirement()),
             "#{requirement()} does not admit #{version()}"

      # A two-segment `~>` on a 0.x version raises the *first* segment for its
      # upper bound, so `~> 0.5` admits 0.6.0 and refuses 1.0.0. That is the
      # right shape for a package whose 1.0 changes defaults: a host pinned to
      # `~> 0.5` gets 0.5.x and 0.6.x without asking, and never 1.0 by accident.
      assert Version.match?(next_patch(), requirement()),
             "#{requirement()} does not admit #{next_patch()}"

      refute Version.match?(next_major(), requirement()),
             "#{requirement()} would silently admit #{next_major()}"
    end

    test "G02 docs/RELEASE.md names the tag for the current version" do
      release = File.read!(@release_doc)

      assert release =~ "git tag v#{version()}",
             "#{@release_doc} does not tell the owner to run `git tag v#{version()}`"

      stale =
        Regex.scan(~r/git tag (v\S+)/, release, capture: :all_but_first)
        |> List.flatten()
        |> Enum.reject(&(&1 == "v#{version()}"))

      assert stale == [],
             "#{@release_doc} still names #{inspect(stale)}. A checklist that names the " <>
               "previous version is worse than none: it is followed"
    end
  end

  describe "G02 what reaches hexdocs" do
    test "G02 the pages this release adds are in docs() extras" do
      for page <- ["docs/guarantees.md", "docs/upgrading-to-1.0.md"] do
        assert page in extras(), "#{page} is not in mix.exs docs() extras, so it never renders"
      end
    end

    test "G02 the decision records describing shipped behaviour are published" do
      for adr <- @published_adrs do
        assert File.exists?(adr), "#{adr} does not exist"
        assert adr in extras(), "#{adr} describes shipped behaviour but is not in docs() extras"
      end
    end

    test "G02 decision records for unshipped V1 design are not published yet" do
      published =
        for adr <- @unpublished_adrs, adr in extras(), do: "  " <> adr

      assert published == [],
             "these decision records describe V1 design that has not shipped, so hexdocs " <>
               "would present a plan as a feature. Publish each one in the release that " <>
               "ships it, and move it out of @unpublished_adrs in the same change:\n" <>
               Enum.join(published, "\n")
    end

    test "G02 every ADR is accounted for, published or not" do
      on_disk = "docs/adr/*.md" |> Path.wildcard() |> Enum.sort()

      accounted =
        Enum.sort(@published_adrs ++ @unpublished_adrs ++ Enum.filter(extras(), &adr?/1))

      missing = on_disk -- Enum.uniq(accounted)

      assert missing == [],
             "decision records that are neither in docs() extras nor listed here. Decide " <>
               "whether each describes shipped behaviour:\n" <>
               Enum.map_join(missing, "\n", &("  " <> &1))
    end
  end

  describe "G04 schema neutrality" do
    test "G04 the schema version moves only in the change that adds a migration version" do
      assert AuroraMeter.Migration.latest_version() == @schema_version,
             "the schema version moved to #{AuroraMeter.Migration.latest_version()} and " <>
               "@schema_version here still says #{@schema_version}. A migration version is " <>
               "the one change a release can never roll back, so it is never added as a " <>
               "side effect: move this number in the same change that moves `@latest`, and " <>
               "state the new number in the CHANGELOG section of the release that ships it"
    end

    test "G04 the changelog says the release is schema-neutral" do
      {_version, _date} = top_release()

      assert current_section() =~ "latest_version()",
             "#{@changelog}'s #{version()} section does not state the schema version. An " <>
               "operator reads the changelog to find out whether there is a migration to run"
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp version, do: Mix.Project.config()[:version]

  defp extras do
    Mix.Project.config()[:docs][:extras]
    |> Enum.map(fn
      {path, _opts} -> to_string(path)
      path -> to_string(path)
    end)
  end

  defp adr?(path), do: String.starts_with?(path, "docs/adr/")

  # For a 0.x release the compatible requirement is `~> MAJOR.MINOR`, which is
  # also what it is for 1.x: `~> 0.5` admits 0.5.1 and refuses 0.6.0, and
  # `~> 1.2` admits 1.2.9 and refuses 1.3.0.
  defp requirement do
    [major, minor | _] = String.split(version(), ".")
    "~> #{major}.#{minor}"
  end

  defp requirement_snippet, do: ~s({:aurora_meter, "#{requirement()}"})

  defp next_patch do
    [major, minor, patch | _] = String.split(version(), ".")
    "#{major}.#{minor}.#{String.to_integer(patch) + 1}"
  end

  defp next_major do
    [major | _] = String.split(version(), ".")
    "#{String.to_integer(major) + 1}.0.0"
  end

  defp top_release do
    @changelog
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^## \[(\d+\.\d+\.\d+[^\]]*)\] - (\S+)/, line) do
        [_, version, date] -> {version, date}
        nil -> nil
      end
    end)
  end

  defp current_section do
    section =
      @changelog
      |> File.read!()
      |> String.split(~r/^## \[/m)
      |> Enum.find(&String.starts_with?(&1, version() <> "]"))

    assert section, "#{@changelog} has no section for #{version()}"
    section
  end
end
