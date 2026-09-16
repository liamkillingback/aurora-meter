# 09b: the storefront markets the package and does not install it

Build unit 09b, task 09.10's second half. Captured 2026-09-16 (UTC).

Task 09.10 asks for the packages' supported LiveView versions and the
storefront's actual 0.19 stack to be tested **separately**, on the grounds that
the storefront markets the package and need not install optional components with
incompatible constraints. This file is the storefront half. The package half is
`09b-optional-deps.md`.

## The suite

Run entirely on its own. `execution-waves.md` rule 7: the storefront suite is
timing sensitive and fails four of its 571 tests when it runs beside another
gate, passing at the same seed with the machine to itself. Nothing else was
running.

    bash tmp/v1/mixlane.sh storefront mix test

    Finished in 2.6 seconds (1.3s async, 1.3s sync)
    Result: 571 passed
    exit=0
    started=2026-09-16T16:18:08Z finished=2026-09-16T16:18:12Z
    log sha256 d8875e3ef5d059c8ecf7c7c3aff1ad7809a9fbc80440229f71a5c9750090bfea

571 of 571, which is the whole suite and the same count `execution-waves.md`
records. Raw log: `tmp/v1/09b/gates/storefront-test.log`.

One operational note, because it cost a run: the storefront's database container
(`phxtemplates-dev-db`, port 5470) was stopped, and the first attempt failed with
`tcp connect (localhost:5470): connection refused` before a single test ran. It
was started with `docker start phxtemplates-dev-db`. Nothing in the storefront
repository changed between the two attempts.

## No package dependency was added

`PhxTemplates/mix.exs` `deps/0` spans lines 34 to 82. Neither `aurora_meter` nor
`aurora_meter_pro` appears anywhere in the file, before or after this unit:

    $ grep -n 'aurora_meter' PhxTemplates/mix.exs
    (no matches)

And the LiveView line the storefront actually runs on, unchanged:

    PhxTemplates/mix.exs:42:      {:phoenix_live_view, "~> 0.19.0"},

That is the point of the separation. The storefront is two majors behind the
requirement this unit now declares for the packages (`~> 1.0`, finding C9,
`09b-components-liveview.md`), and it is entirely unaffected, because it
describes the components in copy and never renders one. If it had installed the
package the narrowing would have been a breaking change for the site that sells
it.

**No file in the storefront repository was modified by this unit.** It is read
only to 09b by the build document's Scope section, and the only thing this unit
produces about it is this report.

## What has to stay true, and who holds it

- **10b** owns the storefront copy that describes the installer and the runtime
  floors. Its claims have to match `AuroraMeter.Install.Support.declared_deps/0`,
  which is now the machine-readable source of truth for the floors and is
  compared against `mix.exs` by a test (`09b-support-matrix.md`).
- If the storefront ever does install the package, it upgrades LiveView first or
  drops the optional dependency, per the two-door upgrade route in
  `docs/support-policy.md`. It has no reason to: nothing it renders comes from
  `AuroraMeter.Components`.
- **I21** (public installation instructions resolve real artifacts) is proved
  properly by the clean-room installs in 09e and 11c, not by this file. What this
  file records is the narrower claim 09.10 actually makes: the two stacks are
  tested separately and neither constrains the other.
