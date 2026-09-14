# Fixture: a section that has lost a field

Used by `AuroraMeter.CorrectnessIndexTest`. It is deliberately malformed: the
`Known limits` field is absent, which the parser must notice and report by id.
Nothing loads this file except that test.

## I01 A section with no known limits

**Guarantee.** Something is guaranteed.

**Prerequisites.** Something must be true.

**Tests.**

- `AuroraMeter.FixtureTest` / `test a bullet that names nothing real`

**Evidence.** `docs/evidence/v1/phase-01/i01.md`
