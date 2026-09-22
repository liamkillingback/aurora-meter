# Releasing Aurora Meter (free core)

Manual, human-run steps, not automated (they touch credentials and the public
Hex registry).

## Pre-flight

```bash
mix check                 # format + compile + credo + dialyzer + test + docs
mix hex.build             # inspect the package contents
mix deps.unlock --check-unused
```

Confirm:

- [ ] `@version` in `mix.exs` and the top `CHANGELOG.md` heading match.
- [ ] `README.md` install snippet uses the new version's `~>` requirement.
- [ ] `package.files` lists everything shipped (no test/demo/priv/plts).
- [ ] The version is not already on hex.pm. Check the registry, not this
      repository: `mix hex.info aurora_meter <version>` must say there is no
      such release. The tree has twice carried a version that told a different
      story from the registry (build unit 11c).

`mix test` enforces the first three: `test/aurora_meter/release_metadata_test.exs`
compares `@version` against the changelog heading, both install snippets and the
`git tag` command below, and fails on any pair that disagrees. The version
appears literally in this file on purpose, so that test can hold it to the
version being released.

## Tag first, then publish

**In this order, and not the other one.** `docs()` sets
`source_ref: "v#{@version}"`, so every "source" link in the published
documentation points at a tag. Publishing before the tag exists ships a
documentation set whose source links 404 until someone notices (finding S8:
core 0.3.0 was published with no tag and its links are still broken).

`mix hex.publish` must also run **from this repository checkout at that tag**,
never from an unpacked tarball. `package.files` deliberately excludes `docs/`,
so an extracted archive can build only the four root extras and would publish a
documentation set missing every guide. That is a property of the archive, not a
fault in it: hexdocs already serves the guides and no consumer compiles them.

```bash
git tag v1.0.0
git push origin main --tags
mix hex.publish           # publishes the package and the docs to hexdocs.pm
```

## Post-release

- [ ] Verify the docs render at https://hexdocs.pm/aurora_meter.
- [ ] Announce (ElixirForum "Your Libraries / Projects", changelog).
