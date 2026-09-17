defmodule AuroraMeterTest do
  @moduledoc false
  # async: false: the facade tests below mutate the node's application
  # environment (`:tenant`) and the node-wide warn-once registry.
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test.Config, only: [with_config: 2]
  import ExUnit.CaptureLog

  alias AuroraMeter.Config.Schema
  alias AuroraMeter.Tenant

  doctest AuroraMeter

  defmodule EmptyKeyTenant do
    @moduledoc false
    # Deliberately returns a key the library refuses. It declares no
    # `@behaviour AuroraMeter.Tenant`: the callback is typed `String.t()` and a
    # fixture that breaks a typed contract makes Dialyzer prove the behaviour
    # unsatisfiable, which fails `mix check` (open-findings.md X65).
    def to_key(_tenant), do: ""
  end

  defmodule NonBinaryTenant do
    @moduledoc false
    # Same reasoning as EmptyKeyTenant: no `@behaviour` on a negative fixture.
    def to_key(_tenant), do: :not_a_binary
  end

  test "version/0 returns a non-empty binary" do
    version = AuroraMeter.version()
    assert is_binary(version)
    assert version != ""
  end

  describe "feature names are atoms" do
    test "a binary feature name raises ArgumentError in strict mode" do
      message =
        assert_raise(ArgumentError, fn -> AuroraMeter.feature!("api_calls", :strict) end).message

      assert message =~ "feature names are atoms"
      assert message =~ "\"api_calls\""
      assert message =~ "Use :api_calls"
      assert message =~ "second in-memory counter for the same database row"
    end

    # Build unit 11c. The third assertion used to go through
    # `AuroraMeter.track/3`, which takes the mode this build was COMPILED at.
    # Cutting 1.0.0-rc.1 moved that from `:transition` to `:strict`
    # (`AuroraMeter.Config.Schema` flips at `1.0.0-rc.0`) and the call started
    # raising, so a test named "in transition mode" was testing whichever mode
    # the version happened to be at. It now drives the transition behaviour
    # through the mode-parameterised seam, which is what that parameter is for,
    # and asserts the strict half separately.
    test "a binary feature name warns once and behaves as today in transition mode" do
      reset_warnings()

      log =
        capture_log(fn ->
          assert AuroraMeter.feature!("api_calls", :transition) == "api_calls"
          assert AuroraMeter.feature!("api_calls", :transition) == "api_calls"
        end)

      assert occurrences(log, "feature names are atoms") == 1
      assert log =~ "Aurora Meter 1.0 raises"
    end

    test "a binary feature name raises in strict mode, which is what this build is" do
      assert Schema.mode() == :strict,
             "this build is not at 1.0, so the release strictness switch has moved"

      assert_raise ArgumentError, ~r/feature names are atoms/, fn ->
        AuroraMeter.track(unique_tenant(), "api_calls", 2)
      end
    end

    test "a feature name that is neither an atom nor a binary raises in both modes" do
      for mode <- [:strict, :transition] do
        assert_raise ArgumentError, ~r/feature names are atoms/, fn ->
          AuroraMeter.feature!(%{not: "a feature"}, mode)
        end
      end
    end

    test "every facade function that takes a feature validates it" do
      tenant = unique_tenant()

      calls = [
        fn feature -> AuroraMeter.track(tenant, feature) end,
        fn feature -> AuroraMeter.usage(tenant, feature) end,
        fn feature -> AuroraMeter.history(tenant, feature) end,
        fn feature -> AuroraMeter.check(tenant, feature) end,
        fn feature -> AuroraMeter.allowed?(tenant, feature) end,
        fn feature -> AuroraMeter.entitled?(tenant, feature) end,
        fn feature -> AuroraMeter.remaining(tenant, feature) end,
        fn feature -> AuroraMeter.feature_value(tenant, feature) end,
        fn feature -> AuroraMeter.quota(tenant, feature) end,
        fn feature -> AuroraMeter.reserve(tenant, feature) end,
        fn feature -> AuroraMeter.reserve(tenant, feature, 1) end,
        fn feature -> AuroraMeter.with_quota(tenant, feature, fn -> :ran end) end,
        fn feature -> AuroraMeter.with_quota(tenant, feature, 1, fn -> :ran end) end
      ]

      for call <- calls do
        assert_raise ArgumentError, ~r/feature names are atoms/, fn -> call.(123) end
      end
    end
  end

  describe "tenant keys" do
    test "an empty tenant key raises in strict mode and warns in transition mode" do
      message =
        assert_raise(ArgumentError, fn ->
          Tenant.validate_key!(EmptyKeyTenant, "", :strict)
        end).message

      assert message =~ "AuroraMeterTest.EmptyKeyTenant"
      assert message =~ "empty tenant key"
      assert message =~ "1.0 raises"

      reset_warnings()

      # 11c: `Tenant.to_key/1` takes the mode this build was compiled at, and
      # this build is 1.0, so it raises rather than warns. The transition half
      # is driven through the seam that takes the mode as a parameter, which is
      # what the parameter exists for.
      log =
        capture_log(fn ->
          assert Tenant.validate_key!(EmptyKeyTenant, "", :transition) == ""
          assert Tenant.validate_key!(EmptyKeyTenant, "", :transition) == ""
        end)

      assert occurrences(log, "empty tenant key") == 1

      with_config([{:aurora_meter, :tenant, EmptyKeyTenant}], fn ->
        assert_raise ArgumentError, ~r/empty tenant key/, fn -> Tenant.to_key(:anything) end
      end)
    end

    test "a tenant module returning a non-binary raises naming the module" do
      with_config([{:aurora_meter, :tenant, NonBinaryTenant}], fn ->
        message = assert_raise(ArgumentError, fn -> Tenant.to_key("anything") end).message

        assert message =~ "AuroraMeterTest.NonBinaryTenant"
        assert message =~ ":not_a_binary"
        assert message =~ "not a binary"
      end)
    end

    test "the tenant-key error never names the term it was given" do
      # A host may meter a struct carrying personal data; the message names the
      # module and what it returned, and nothing else.
      with_config([{:aurora_meter, :tenant, NonBinaryTenant}], fn ->
        message =
          assert_raise(ArgumentError, fn ->
            Tenant.to_key(%{email: "secret@example.com"})
          end).message

        refute message =~ "secret@example.com"
        assert message =~ ":not_a_binary"
      end)
    end
  end

  defp reset_warnings do
    Schema.reset_warnings!()
    on_exit(&Schema.reset_warnings!/0)
  end

  defp occurrences(haystack, needle), do: length(String.split(haystack, needle)) - 1
end
