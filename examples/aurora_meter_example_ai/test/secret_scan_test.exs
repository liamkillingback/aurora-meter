defmodule AuroraMeterExampleAi.SecretScanTest do
  @moduledoc """
  L09d-1: no credential value appears anywhere in the sample tree.

  The scan walks the sample's own directory, both lockfiles and everything
  under `tmp/` (which is where `mix sample.failure` and `scripts/pro-proof.sh`
  write), and fails on anything key shaped. `_build` and `deps` are excluded:
  they are other people's source, they are git-ignored, and a key in a
  dependency's source is not something this repository can fix or should hide.

  **This test and `AuroraMeterExampleAi.Redact` were written before the Pro
  profile used a credential on this machine.** That ordering is the point of
  build unit 09d's implementation step 4.
  """
  # `async: false`, because one test writes a file into the tree that another
  # test scans. Running them concurrently would make the tree scan fail on a
  # planted string roughly half the time, which is the shape of flake that
  # gets a test deleted rather than fixed.
  use ExUnit.Case, async: false

  alias AuroraMeterExampleAi.Redact

  # ---------------------------------------------------------------------------
  # Why these are assembled rather than written out
  # ---------------------------------------------------------------------------
  #
  # A scan for key-shaped strings, written with key-shaped example strings in
  # it, finds itself. That is not a hypothetical: the first version of this
  # file failed its own tree scan, naming this file and `lib/.../redact.ex`,
  # which is precisely how a scan gets an exclusion list bolted on and quietly
  # stops covering the two files most likely to handle a key.
  #
  # Concatenating the prefix and the body means no contiguous match exists in
  # the source, while the value the test uses at runtime is byte for byte what
  # a real one looks like. The scan therefore covers every file in the tree
  # with no exceptions, which is the property worth having.
  @fake_secret_key "sk_test_" <> "51QhAbCdEfGhIjKlMnOp"
  @fake_restricted_key "rk_live_" <> "0123456789abcdefghij"
  @fake_publishable_live "pk_live_" <> "0123456789abcdefghij"
  @fake_publishable_test "pk_test_" <> "51QhAbCdEfGhIjKlMnOp"
  @fake_webhook_secret "whsec_" <> "0123456789abcdefghij"
  @fake_fragment "sk_test_" <> "51Qh"

  @root Path.expand("..", __DIR__)
  @skip_dirs ~w(_build deps node_modules .git .elixir_ls .lexical)
  # priv/static holds build output; assets/vendor holds vendored JavaScript.
  # Both are bytes nobody in this repository typed, and both are big enough to
  # make the scan slow for no gain.
  @skip_rel ~w(priv/static assets/vendor)

  describe "the scan itself" do
    test "L09d-1 the scan patterns match a real-shaped key and not a documentation example" do
      # A scan that cannot be shown to fire is a scan that has never been seen
      # working. These two strings are the discriminator: the first has the
      # eight-character body a real key has, the second is the bare prefix that
      # appears in this repository's own refusal messages and documentation.
      assert credential_shaped?(@fake_secret_key)
      assert credential_shaped?(@fake_webhook_secret)
      assert credential_shaped?(@fake_restricted_key)
      assert credential_shaped?(@fake_publishable_live)

      refute credential_shaped?("must begin sk_test_")
      refute credential_shaped?("STRIPE_WEBHOOK_SECRET must match ^whsec_")
      refute credential_shaped?(@fake_publishable_test)
    end

    test "L09d-1 the redaction filter replaces a key-shaped string in a log line" do
      line = "POST /v1/checkout/sessions Authorization: Bearer " <> @fake_secret_key
      redacted = Redact.line(line)

      refute credential_shaped?(redacted)
      refute redacted =~ "51QhAbCdEfGhIjKlMnOp"
      assert redacted =~ "[redacted]"

      # And the negative leg: a line with nothing in it comes back unchanged,
      # so "the filter redacted it" is distinguishable from "the filter
      # rewrites everything".
      assert Redact.line("outbox item 7f3a delivered") == "outbox item 7f3a delivered"
    end

    test "L09d-1 the redaction filter catches a truncated key, which the scan deliberately does not" do
      # The two lists differ on purpose and this test is where that decision is
      # pinned. `Redact.line/1` must swallow a fragment; the repository scan
      # must not fire on one, or it fires on this file.
      assert Redact.line(@fake_fragment) == "[redacted]"
      refute credential_shaped?(@fake_fragment)
    end
  end

  describe "the sample tree" do
    test "L09d-1 no file in the sample tree matches a Stripe, Hex or webhook secret pattern" do
      offenders =
        @root
        |> scannable_files()
        |> Enum.filter(fn path ->
          case File.read(path) do
            {:ok, contents} -> credential_shaped?(contents)
            _ -> false
          end
        end)
        |> Enum.map(&Path.relative_to(&1, @root))

      assert offenders == [],
             "credential-shaped strings found in: #{Enum.join(offenders, ", ")}"
    end

    test "L09d-1 a crash dump, if there is one, is scanned rather than skipped" do
      # `erl_crash.dump` is git-ignored, which is not the same as safe. A dump
      # is a picture of every process in the VM at the moment it died, and in
      # the Pro profile the Stripe API key is in the application environment.
      # One appeared in this tree during 09d (7.8 MB, from a `mix run` that
      # failed to start the Repo); it was checked and contained no key, and it
      # was deleted.
      #
      # What this test pins is that the scan REACHES such a file: `.dump` is
      # deliberately not in the binary-extension skip list, so a dump in the
      # tree is read like any other file. gitleaks, run over the same tree,
      # found fourteen JWT-shaped strings in that dump and nothing this scan
      # looks for, which is the difference between the two instruments rather
      # than a disagreement.
      path = Path.join(@root, "erl_crash.dump")
      File.write!(path, "a dump containing " <> @fake_secret_key <> " and nothing else\n")

      try do
        assert path in scannable_files(@root),
               "a crash dump in the sample tree is not reached by the scan"

        assert credential_shaped?(File.read!(path))
      after
        File.rm(path)
      end

      refute File.exists?(path)
    end

    test "L09d-1 the scan actually reaches files, so an empty result means clean and not empty" do
      files = scannable_files(@root)

      # Without this the previous test passes on a walker that returns [].
      assert length(files) > 50

      relative = Enum.map(files, &Path.relative_to(&1, @root))
      assert "mix.exs" in relative
      assert "README.md" in relative
      assert "test/secret_scan_test.exs" in relative
      assert Enum.any?(relative, &String.starts_with?(&1, "lib/"))

      # And it does not reach the places it is documented not to reach.
      refute Enum.any?(relative, &String.starts_with?(&1, "deps/"))
      refute Enum.any?(relative, &String.starts_with?(&1, "_build/"))
    end
  end

  describe "the configuration example" do
    test "L09d-1 .env.example exists and has only empty values" do
      path = Path.join(@root, ".env.example")
      assert File.exists?(path), ".env.example is part of the Pro profile's documentation"

      offenders =
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> Enum.reject(&String.match?(&1, ~r/^[A-Z][A-Z0-9_]*=$/))

      assert offenders == [],
             ".env.example must list names with empty values only; found: #{inspect(offenders)}"
    end

    test "L09d-1 .env is git-ignored and untracked" do
      ignore = Path.join(@root, ".gitignore") |> File.read!()

      assert ignore =~ ~r/^\.env$/m or ignore =~ ~r/^\/\.env$/m,
             ".gitignore must ignore .env"

      {out, status} =
        System.cmd("git", ["ls-files", "--error-unmatch", ".env"],
          cd: @root,
          stderr_to_stdout: true
        )

      assert status != 0, ".env is tracked by git: #{out}"
    end
  end

  describe "the lockfiles" do
    test "L09d-1 both lockfiles exist and neither contains a credential-shaped string" do
      for name <- ~w(mix.lock mix.pro.lock) do
        path = Path.join(@root, name)

        assert File.exists?(path),
               "#{name} is committed so both profiles are reproducible (09d, two-lockfile mechanism)"

        refute credential_shaped?(File.read!(path)),
               "#{name} contains something credential shaped"
      end
    end

    test "L09d-1 mix.pro.lock locks what the Pro profile adds and carries no key" do
      lock = Path.join(@root, "mix.pro.lock") |> File.read!()

      # `aurora_meter_pro` itself is deliberately not asserted here. In this
      # repository it resolves as a path dependency to the sibling checkout,
      # and a path dependency is never locked: there is no version, no
      # checksum and no repository to pin. What IS lockable is what Pro brings
      # with it, and those two are the Pro profile's fingerprint in the file.
      for package <- ~w(oban stripity_stripe) do
        assert lock =~ ~s|"#{package}"|
      end

      # A Hex lock entry records a package name, a version, a checksum and a
      # repository. None of those is a credential: the key that authorises the
      # private repository lives in the operator's ~/.hex/hex.config and never
      # reaches a project file. This asserts that nothing key shaped got in
      # anyway.
      refute lock =~ ~r/hexpm:[A-Za-z0-9]{20,}/, "a Hex key shape appears in mix.pro.lock"
      refute credential_shaped?(lock)
    end
  end

  defp credential_shaped?(text), do: Redact.credential_shaped?(text)

  defp scannable_files(root) do
    root
    |> walk()
    |> Enum.reject(fn path ->
      rel = Path.relative_to(path, root)
      Enum.any?(@skip_rel, &String.starts_with?(rel, &1))
    end)
  end

  defp walk(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in @skip_dirs))
        |> Enum.flat_map(fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) -> walk(path)
            binary?(path) -> []
            true -> [path]
          end
        end)

      _ ->
        []
    end
  end

  # A PNG is not going to contain a key and reading every image doubles the
  # scan's time. Decided by extension rather than by content sniffing, so the
  # rule is legible.
  @binary_extensions ~w(.png .jpg .jpeg .gif .ico .woff .woff2 .ttf .eot .svg .tar .gz .beam .ez)
  defp binary?(path), do: Path.extname(path) in @binary_extensions
end
