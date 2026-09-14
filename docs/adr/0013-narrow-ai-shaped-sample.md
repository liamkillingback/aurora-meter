# ADR 0013: A narrow AI shaped sample application

Status: accepted for Aurora Meter V1, 2026-09-14.

Prerequisite ADR: 0001 (resolved decisions), which recorded the scope discipline
this file narrows by exactly one item.

## Context

`plan.md:99` lists "**Anything AI or agent-related.** (This is the trap the
predecessor fell into.)" as a hard non goal, and gives the reason in the same
line: the predecessor project died of that scope creep. The V1 programme wants a
canonical sample whose workload looks like the metered workloads customers
actually bring, which today usually means per request token counts.

That is a deliberate crossing of a recorded non goal, and V1 decision D10 requires
it to be recorded rather than quietly taken. This ADR is that record.

## Decision

The canonical sample under core `examples/` simulates a token shaped workload: a
deterministic generator that produces per request token counts from a seed, used
purely as an integration example for metered usage.

The sample ships MIT. It runs with core alone, calls no AI provider, holds no
provider key and needs no network. Its optional Pro profile uses Stripe test mode
only and never embeds a key or any Pro source.

No AI code, model client, prompt handling or agent runtime enters the `lib/`
directory of either package. The exception is exactly one deterministic workload
generator inside `examples/`, and nothing else.

## Consequences

The non goal at `plan.md:99` is narrowed, not repealed. A later unit that wants to
add a model client, a prompt template, an embedding helper or an agent loop is
outside this exception and needs its own decision; pointing at this ADR is not
enough.

Storefront copy on `aurorameter.com` may describe the sample as AI shaped usage.
It must not describe Aurora Meter as an AI product, and unit 10b owns that claim.
The distinction matters commercially as well as honestly: the package's value is
that it meters anything, and an AI label narrows the market it can address while
inviting a comparison with tools that do inference.

Because the generator is deterministic and offline, the sample is also testable in
CI and reproducible in a clean room, which the demo it replaces was not.

## Migration impact

None. No schema change, no column, no backfill, no task.

## Verification

Unit 09c and 09d (the sample runs on core alone with no network and no provider
key; the Pro profile is opt in), 09e (clean room install) and 10b (the claims made
about it in storefront copy). None of these tests exists yet.
