defmodule AuroraMeter.PlansSnapshotTest do
  @moduledoc false
  # Build unit 07a. The canonical form a plan fingerprint is taken over, and the
  # jsonb shape that makes a retired version readable.
  #
  # Every test here is a unit test over pure functions, so it is async. The
  # fingerprint is the thing the whole of I17 rests on: too strict and every
  # host's first 1.0 boot refuses, too loose and a real repricing is accepted in
  # silence.
  use ExUnit.Case, async: true

  alias AuroraMeter.Plan
  alias AuroraMeter.Plans.Snapshot

  @rs "\x1e"
  @us "\x1f"

  defp plan(overrides \\ []) do
    base = %Plan{
      id: :pro,
      version: "1",
      price: 2_000,
      features: %{ai_generations: {:limit, 1_000, :hard}},
      recurring_credits: [],
      effective_at: nil
    }

    struct!(base, overrides)
  end

  defp fingerprint(overrides), do: Snapshot.fingerprint(plan(overrides))

  test "I17 the canonical form renders every commercial field with visible separators" do
    canonical =
      Snapshot.canonical(
        plan(
          features: %{ai_generations: {:limit, 1_000, :hard}, api_access: {:feature, true}},
          recurring_credits: [
            %{
              name: :monthly,
              amount: 5_000_000,
              category: :promotional,
              rollover: 1_000_000,
              expires: :period_end
            }
          ]
        )
      )

    assert canonical ==
             Enum.join(
               [
                 "v1",
                 "id#{@us}pro",
                 "version#{@us}1",
                 "price#{@us}i2000",
                 "features",
                 "f#{@us}ai_generations#{@us}limit#{@us}i1000#{@us}hard",
                 "f#{@us}api_access#{@us}feature#{@us}bool#{@us}true",
                 "recurring_credits",
                 "c#{@us}monthly#{@us}amount#{@us}i5000000#{@us}category#{@us}promotional" <>
                   "#{@us}rollover#{@us}i1000000#{@us}expires#{@us}period_end"
               ],
               @rs
             )
  end

  test "I17 the fingerprint is the sha256 of the canonical form and is 32 bytes" do
    plan = plan()

    assert Snapshot.fingerprint(plan) == :crypto.hash(:sha256, Snapshot.canonical(plan))
    assert byte_size(Snapshot.fingerprint(plan)) == 32
  end

  test "I17 the fingerprint is independent of feature declaration order" do
    # Two maps built by inserting the same pairs in opposite orders. Small maps
    # in the BEAM are sorted by key, so this alone cannot discriminate: the next
    # test is the one that puts iteration order in play.
    forwards =
      %{} |> Map.put(:a_feature, {:counter}) |> Map.put(:z_feature, {:limit, 5, :hard})

    backwards =
      %{} |> Map.put(:z_feature, {:limit, 5, :hard}) |> Map.put(:a_feature, {:counter})

    assert fingerprint(features: forwards) == fingerprint(features: backwards)
  end

  test "I17 the fingerprint is independent of map iteration order above the small-map boundary" do
    # A map with more than 32 keys is a hash map, whose iteration order is a
    # property of the hashes and not of the keys. Building the same 40 features
    # in two orders is what actually exercises L17.3's "independent of map
    # iteration order", because below 32 keys Erlang sorts them for you.
    pairs = for n <- 1..40, do: {:"feature_#{n}", {:limit, n, :hard}}

    forwards = Map.new(pairs)
    backwards = pairs |> Enum.reverse() |> Map.new()
    shuffled = pairs |> Enum.shuffle() |> Map.new()

    assert map_size(forwards) == 40
    assert fingerprint(features: forwards) == fingerprint(features: backwards)
    assert fingerprint(features: forwards) == fingerprint(features: shuffled)
  end

  test "I17 the canonical form lists features in name order, whatever order the map iterates in" do
    # The assertion that names the mechanism rather than an effect, and it
    # exists because the effect could not be discriminated: removing the sort
    # broke no equality test in this file (finding X291). Within one BEAM an
    # Erlang map iterates deterministically for a given key set, so two maps
    # with the same keys always render alike whether or not the renderer sorts.
    # What the sort is actually for is stability **across** ERTS versions, where
    # a hash map's iteration order is an implementation detail, and the only way
    # to test that from inside one BEAM is to assert the order directly.
    pairs = for n <- 1..40, do: {:"feature_#{n}", {:limit, n, :hard}}
    features = Map.new(pairs)

    rendered =
      features
      |> then(&plan(features: &1))
      |> Snapshot.canonical()
      |> String.split(@rs)
      |> Enum.filter(&String.starts_with?(&1, "f" <> @us))
      |> Enum.map(fn line -> line |> String.split(@us) |> Enum.at(1) end)

    assert length(rendered) == 40
    assert rendered == Enum.sort(rendered)

    # And the control the assertion above needs to be worth anything: the map's
    # own iteration order is not the sorted one, so an unsorted renderer really
    # would produce a different list.
    iterated = features |> Map.keys() |> Enum.map(&Atom.to_string/1)

    refute iterated == Enum.sort(iterated),
           "this map iterates in sorted order, so the assertion above cannot tell a sorting " <>
             "renderer from an unsorted one. Use more keys, or keys whose hash order differs."
  end

  test "I17 the fingerprint is independent of recurring credit declaration order" do
    first = %{
      name: :monthly,
      amount: 1_000,
      category: :promotional,
      rollover: 0,
      expires: :period_end
    }

    second = %{
      name: :quarterly,
      amount: 2_000,
      category: :promotional,
      rollover: 0,
      expires: :period_end
    }

    assert fingerprint(recurring_credits: [first, second]) ==
             fingerprint(recurring_credits: [second, first])
  end

  test "I17 the fingerprint changes when any commercial field changes" do
    baseline = fingerprint([])

    changes = [
      {"the plan id", [id: :scale]},
      {"the version", [version: "2"]},
      {"the price", [price: 2_001]},
      {"a limit", [features: %{ai_generations: {:limit, 1_001, :hard}}]},
      {"a feature kind", [features: %{ai_generations: {:counter}}]},
      {"a feature name", [features: %{other_generations: {:limit, 1_000, :hard}}]},
      {"a boolean feature value", [features: %{api_access: {:feature, true}}]},
      {"a metered included count", [features: %{tokens: {:metered, 10, 2}}]},
      {"a metered unit price", [features: %{tokens: {:metered, 10, 3}}]},
      {"an integer feature value", [features: %{seats: {:feature, 5}}]},
      {"a recurring credit amount",
       [
         recurring_credits: [
           %{
             name: :monthly,
             amount: 1,
             category: :promotional,
             rollover: 0,
             expires: :period_end
           }
         ]
       ]},
      {"a recurring credit rollover cap",
       [
         recurring_credits: [
           %{
             name: :monthly,
             amount: 1,
             category: :promotional,
             rollover: 5,
             expires: :period_end
           }
         ]
       ]},
      {"a recurring credit category",
       [
         recurring_credits: [
           %{name: :monthly, amount: 1, category: :paid, rollover: 0, expires: :never}
         ]
       ]}
    ]

    for {what, overrides} <- changes do
      refute fingerprint(overrides) == baseline, "changing #{what} did not change the fingerprint"
    end

    # And every one of them is distinct from every other, so the renderer is not
    # collapsing two different changes into one digest.
    digests = Enum.map(changes, fn {_what, overrides} -> fingerprint(overrides) end)
    assert length(Enum.uniq(digests)) == length(digests)
  end

  test "I17 the effective instant is not commercial content and does not change the fingerprint" do
    # Deliberate, and the reason is in `AuroraMeter.Plans.Snapshot`'s comment
    # (finding X290). `effective_at` says when a version starts applying to NEW
    # subscriptions; an existing subscription is pinned to its version and is
    # not moved by it, so changing it cannot reprice anybody. Making it a
    # conflict would also make `v1-release.md` 07.03 unreachable: deleting a
    # retired base version forces the version left behind to drop its instant.
    assert fingerprint(effective_at: ~U[2026-10-01 00:00:00Z]) ==
             fingerprint(effective_at: ~U[2030-01-01 00:00:00Z])

    assert fingerprint(effective_at: nil) == fingerprint(effective_at: ~U[2030-01-01 00:00:00Z])

    # It is still stored, so a version no longer in code can report when it
    # started.
    assert Snapshot.encode(plan(effective_at: ~U[2026-10-01 00:00:00Z]))["effective_at"] ==
             "2026-10-01T00:00:00Z"
  end

  test "I17 an integer and a float unit price produce different fingerprints" do
    integer = fingerprint(features: %{tokens: {:metered, 10, 2}})
    float = fingerprint(features: %{tokens: {:metered, 10, 2.0}})

    refute integer == float
  end

  test "I17 a boolean feature value and the integer 1 produce different fingerprints" do
    refute fingerprint(features: %{seats: {:feature, true}}) ==
             fingerprint(features: %{seats: {:feature, 1}})
  end

  test "I17 encode then decode round-trips a plan" do
    original =
      plan(
        version: "2",
        effective_at: ~U[2026-10-01 00:00:00Z],
        features: %{
          ai_generations: {:limit, 1_000, :hard},
          tokens: {:metered, 10, 2},
          requests: {:counter},
          api_access: {:feature, true},
          seats: {:feature, 5}
        },
        recurring_credits: [
          %{
            name: :monthly,
            amount: 5_000_000,
            category: :promotional,
            rollover: 1_000_000,
            expires: :period_end
          }
        ]
      )

    definition = original |> Snapshot.encode() |> json_round_trip()

    assert {:ok, decoded, []} =
             Snapshot.decode("pro", "2", definition, original.effective_at, nil)

    assert decoded.id == original.id
    assert decoded.version == original.version
    assert decoded.price == original.price
    assert decoded.features == original.features
    assert decoded.recurring_credits == original.recurring_credits
    assert decoded.effective_at == original.effective_at

    # The point of the round trip: the decoded plan fingerprints the same, so a
    # snapshot read back out of jsonb is the same commercial content by the one
    # measure `register!/0` uses.
    assert Snapshot.fingerprint(decoded) == Snapshot.fingerprint(original)
  end

  test "I17 decode drops a feature name with no existing atom and names it" do
    definition = %{
      "fingerprint_version" => 1,
      "price" => 2_000,
      "effective_at" => nil,
      "features" => %{
        "ai_generations" => ["limit", 1_000, "hard"],
        "no_such_feature_atom_anywhere" => ["counter"]
      },
      "recurring_credits" => []
    }

    assert {:ok, decoded, dropped} = Snapshot.decode("pro", "1", definition, nil, nil)

    assert dropped == ["no_such_feature_atom_anywhere"]
    assert decoded.features == %{ai_generations: {:limit, 1_000, :hard}}
  end

  test "I17 decode refuses a plan id with no existing atom rather than creating one" do
    assert {:error, {:unknown_atom, "no_such_plan_atom_anywhere"}} =
             Snapshot.decode("no_such_plan_atom_anywhere", "1", %{}, nil, nil)

    # The claim, stated directly rather than through an atom-table count, which
    # any concurrently compiling module can move: the atom still does not exist,
    # so `decode/5` used `String.to_existing_atom/1`. A decoder that created
    # atoms from a jsonb column would be an unbounded atom table away from
    # taking the node down, and `definition` is read back out of a database.
    assert_raise ArgumentError, fn -> String.to_existing_atom("no_such_plan_atom_anywhere") end
  end

  test "I17 the separators cannot appear in a name the DSL accepts" do
    refute Snapshot.renderable?("a" <> @rs <> "b")
    refute Snapshot.renderable?("a" <> @us <> "b")
    assert Snapshot.renderable?("ai_generations")
  end

  test "I17 short/1 renders twelve hex characters, or says there is no fingerprint" do
    assert Snapshot.short(nil) == "(none)"
    assert Snapshot.short(:crypto.hash(:sha256, "x")) =~ ~r/\A[0-9a-f]{12}\z/
  end

  # The definition column is jsonb, so what `decode/1` really receives is what
  # Postgres gives back: string keys, and no atoms anywhere. Encoding and
  # decoding through Jason reproduces that without a database.
  defp json_round_trip(map), do: map |> Jason.encode!() |> Jason.decode!()
end
