defmodule AuroraMeter.StorageCaseEctoTest do
  @moduledoc """
  The conformance suite against the adapter that ships (build unit 03b).

  Non-sandbox connections, because the suite's assertions are about what a
  commit leaves behind.
  """
  use ExUnit.Case, async: false

  use AuroraMeter.StorageCase,
    adapter: AuroraMeter.Storage.Ecto,
    checkout: {AuroraMeter.Test.Connections, :checkout!},
    tenant_prefix: "storagecase"

  alias AuroraMeter.Test.Connections

  setup do
    Connections.register_prefix("storagecase")
    on_exit(fn -> Connections.cleanup!("storagecase") end)
    :ok
  end
end

defmodule AuroraMeter.StorageCaseIncapableTest do
  @moduledoc """
  The same suite against an adapter that declares no durable capabilities.

  It passes, and that is the point: declining the work is a supported answer,
  and an adapter author needs a way to say so that a caller can handle.
  """
  use ExUnit.Case, async: false

  use AuroraMeter.StorageCase,
    adapter: AuroraMeter.Test.IncapableStorage,
    checkout: {AuroraMeter.Test.Connections, :checkout!},
    tenant_prefix: "storagecase"

  test "the incapable adapter really declares nothing" do
    assert AuroraMeter.Storage.capabilities() == []
  end

  test "and the facade turns that into an error a caller can handle" do
    assert {:error, {:unsupported, :durable_events}} =
             AuroraMeter.record("storagecase_facade", :ai_generations, 1,
               id: "no",
               occurred_at: DateTime.utc_now()
             )
  end
end
