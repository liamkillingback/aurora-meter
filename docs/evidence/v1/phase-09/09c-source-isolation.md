# 09c: one input source, one commercial effect (I08)

The sample declares `feature_sources: %{tokens: :events}` and leaves `:images`
buffered. That one line is the difference between two entirely separate paths
through the library, and the point of putting both in one application is that
the separation is otherwise something you have to take on trust.

Configuration, written by `mix aurora_meter.install --events-source tokens:events`:

```elixir
config :aurora_meter,
  undeclared_feature_policy: :deny,
  feature_sources: %{tokens: :events}
```

## 1. Figures from the live database

Collected by `tmp/v1/09c-collect.sh` after twelve seeded generations, one image
generation from the browser and one refused generation.

### `globex` (`org_2`)

| Figure | Value | Read through |
|---|---|---|
| `tokens` counter | 592 | `AuroraMeter.usage(org, :tokens)`, a projection of the durable events |
| `tokens` staged in the outbox | 592 | the sample's own `sample_outbox_items`, summed |
| token outbox rows | 13 | one per recorded event |
| `images` counter | 4 | `AuroraMeter.usage(org, :images)`, the buffered ETS counter |
| **image outbox rows** | **0** | |

The last row is the one to read. The outbox callback is invoked by
`AuroraMeter.record/4` inside the transaction that writes an event, and a
buffered feature never produces an event, so a buffered feature can never reach
it. Not "does not today": cannot.

The first two rows agreeing is the other half. The host's independent count of
what it staged for export is the same number as the library's projected counter,
which is what "the counter is a projection of the events" means when it is true.

### Quotas, both kinds

```
globex: quota(:images) = %{kind: :hard,    used: 4,   limit: 200,       remaining: 196}
        quota(:tokens) = %{kind: :metered, used: 592, included: 2000000, overage: 0}
acme:   quota(:images) = %{kind: :hard,    used: 0,   limit: 5,         remaining: 5}
        quota(:tokens) = %{kind: :metered, used: 0,   included: 50000,   overage: 0}
```

`:api_calls` is declared as a counter on both plans and is zero: it exists so the
sample's plans module shows the third kind, which is measured and never blocked
and never billed.

## 2. The flush batch

`generations_test.exs` "tokens never appears in a flush batch and images always
does":

```elixir
features =
  case AuroraMeter.Store.snapshot_flush_batch() do
    nil -> []
    %{counters: counters} -> counters |> Enum.filter(&(&1.tenant_key == key)) |> Enum.map(& &1.feature)
  end

assert :images in features,
       "the buffered feature was absent from the flush batch, so the negative below proves nothing: #{inspect(features)}"

refute :tokens in features
```

**The positive assertion comes first and it is not decoration.** A flush batch
that was empty for any reason at all, a wrong tenant key, a snapshot taken
before the generation, a counter that never dirtied, would satisfy the negative
perfectly. This is the shape the programme has paid for repeatedly (X325, X350,
X360): a test that can only observe the absence of a thing passes on every tree
where the instrument is broken.

## 3. `track/4` raises for an events-source feature

`generations_test.exs` "AuroraMeter.track/4 raises for an events-source feature":

```elixir
assert_raise ArgumentError, fn -> AuroraMeter.track(scope.org, :tokens) end
```

A feature has exactly one reporting source. Counting it twice is how a bill stops
matching the events behind it, and the library refuses at the call site rather
than at reconciliation time.

## 4. Nothing buffered reaches the outbox

`generations_test.exs` "images never reaches the outbox and tokens always does":

```elixir
features = SampleOutbox.Item |> Repo.all() |> Enum.map(& &1.feature) |> Enum.uniq()
assert features == ["tokens"]
```

An exact-equality assertion rather than a `refute ... in ...`, so an empty table
fails it. An image generation is run first, so there is something for the
assertion to be wrong about.

## 5. On the page

`/ops` renders the five figures from section 1 side by side under the heading
"One input source, one commercial effect", with the last one labelled "a
buffered feature never reaches the outbox".

`ops_live_test.exs` "an image generation puts nothing in the outbox and something
in the buffered counter" asserts all five through `Ops.sources/1` and then checks
the label is on the page.

## 6. The one place a reader can see the difference cost something

The first `mix sample.seed` ran in its own short-lived VM and did not flush. The
seeded image usage was lost with that VM and `/generate` showed `images 0 / 200`
for an organisation that had used three; the seeded **token** usage was there,
because it was durable. That is documented behaviour rather than a defect
(everything not in an acknowledged flush batch can be lost with the VM), and it
is the single clearest demonstration of why the two sources exist.

The seed now ends with `{:ok, _flushed} = AuroraMeter.Flusher.flush()` and a
comment saying exactly the above. Nothing in the library changed.
