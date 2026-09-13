# Releasing Aurora Meter (free core)

Manual, human-run steps — not automated (they touch credentials and the public
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

## Publish

```bash
mix hex.publish           # publishes the package and the docs to hexdocs.pm
```

## Tag

```bash
git tag v0.4.0
git push origin main --tags
```

## Post-release

- [ ] Verify the docs render at https://hexdocs.pm/aurora_meter.
- [ ] Announce (ElixirForum "Your Libraries / Projects", changelog).
