# 09d: secret hygiene

Build unit 09d, invariant L09d-1. The scan, the redaction filter, gitleaks, and
a statement about what is in the evidence.

> **Standing rule.** No credentials, no customer identities, no unsanitised
> logs. Synthetic tenant ids only.

Rule 4 applies. Nothing in this file ticks a checkbox and nothing is committed.

Run on 2026-09-17.

---

## 0. The ordering, which is the point

`AuroraMeterExampleAi.Redact` and `test/secret_scan_test.exs` were written
**before** any Stripe credential was used by this unit on this machine. That is
the build document's implementation step 4 and it is not a preference: a
redaction filter added after the first leak is a filter that redacts the second
one.

---

## 1. The scan

`test/secret_scan_test.exs` walks every file under the sample directory,
excluding `_build`, `deps`, `node_modules`, `.git`, `priv/static` and
`assets/vendor`, and fails on:

| pattern | what it is |
|---|---|
| `\b(sk\|rk)_(test\|live)_[A-Za-z0-9]{8,}` | a Stripe secret or restricted key |
| `\bpk_live_[A-Za-z0-9]{8,}` | a live publishable key |
| `\bwhsec_[A-Za-z0-9_\-]{8,}` | a webhook signing secret |

`pk_test_` is deliberately **not** matched: it is designed to be embedded in a
page, and redacting it hides a configuration mistake rather than a secret.

The `{8,}` is why the scan is still switched on. Without it the pattern fires
on the bare prefixes in this repository's own refusal messages, in
`.env.example`, in `config/pro.exs` and in the scan's own documentation, and a
scan that fires on the file that describes it acquires an exclusion list within
a week. Eight or more key characters is what no documentation example has and
every real key does.

### The scan found itself first, and the fix is not an exclusion

The first version failed naming two files: `test/secret_scan_test.exs` and
`lib/aurora_meter_example_ai/redact.ex`. Both contained key-shaped example
strings, because both are about key-shaped strings.

The fix is that every such example is **assembled** (`"sk_test_" <>
"51QhAbCdEfGhIjKlMnOp"`), in the test, in the module's doctests and in
`config/pro_test.exs`'s webhook secret. No contiguous match exists in any
source file, the value at runtime is byte for byte what a real one looks like,
and **the scan covers every file in the tree with no exceptions**, which is the
property worth having.

### Observed

```
$ grep -rlE '\b(sk|rk)_(test|live)_[A-Za-z0-9]{8,}|\bwhsec_[A-Za-z0-9_-]{8,}|\bpk_live_[A-Za-z0-9]{8,}' . \
    --exclude-dir=_build --exclude-dir=deps --exclude-dir=node_modules
(no output)

$ grep -rlE '...' tmp/
(no output)
```

and as a test, in both profiles:

```
test the sample tree L09d-1 no file in the sample tree matches a Stripe, Hex or webhook secret pattern
test the sample tree L09d-1 the scan actually reaches files, so an empty result means clean and not empty
  (asserts > 50 files, and that mix.exs, README.md and lib/ are among them)
```

---

## 2. The lockfiles, `.env` and `.env.example`

| assertion | observed |
|---|---|
| `mix.lock` exists | yes, sha256 `c90e4cc23d61d999`, 54 entries |
| `mix.pro.lock` exists | yes, sha256 `f673928e8316bab0`, 65 entries |
| neither contains a credential shape | confirmed |
| `mix.pro.lock` has no `hexpm:<20+ chars>` key shape | confirmed |
| `.env.example` lines of the form `NAME=` | **12** |
| `.env.example` lines of the form `NAME=value` | **0** |
| `/.env` in `.gitignore` | line 40 |
| `.env` tracked by git | **no** (`git ls-files --error-unmatch` exits non-zero) |

A Hex lock entry records a package name, a version, a checksum and a
repository. None of those is a credential: the key that authorises a private
repository lives in the operator's `~/.hex/hex.config` and never reaches a
project file.

---

## 3. The redaction filter

`AuroraMeterExampleAi.Redact.line/1` replaces anything matching a wider set of
patterns than the scan uses, including a **fragment** of a key, and the two
lists differ on purpose:

| | matches `sk_test_51Qh` (a 4-character fragment) |
|---|---|
| `Redact.line/1` | **yes**, so a truncated key in an error message cannot survive |
| the repository scan | **no**, so it does not fire on this repository's own prose |

Both directions are asserted, in one test, so the difference is a decision
rather than an oversight.

Everything `mix sample.failure` prints and everything it writes to
`tmp/sample-failures/*.json` goes through the filter, even though nothing in a
core-profile recipe can carry a credential. The decision is made once rather
than per field.

`scripts/v1/profiles/sample.sh` inherits the harness's own sanitiser
(`v1_register_secret` plus `v1_sanitize`), which is what turned the webhook
signing secret into `<redacted:STRIPE_WHSEC>` in the `stripe listen` transcript.

---

## 4. gitleaks

`gitleaks detect --source . --no-git --redact -v` over the sample tree,
2026-09-17:

```
scanned ~153465709 bytes (153.47 MB) in 8.89s
leaks found: 14
```

**All fourteen were in `erl_crash.dump`**, all of RuleID `jwt`, all
base64-decoded strings inside a 7.8 MB Erlang crash dump left by a `mix run`
that failed to start the Repo earlier the same day. None of them is a Stripe
key, a webhook secret or a Hex key: the dump was checked for `sk_test_` and the
prefix does not appear in it.

The dump was git-ignored (`.gitignore:17`) and untracked, and it has been
deleted.

**It is worth more than its disposal, though.** A crash dump is a picture of
every process in the VM at the moment it died, and in the Pro profile the
Stripe API key is in the application environment. Git-ignored is not the same
as safe. So:

- the scan's binary-extension skip list deliberately does **not** include
  `.dump`, so a dump in the tree is read like any other file;
- `test/secret_scan_test.exs` has a test that writes a dump containing an
  assembled key shape, asserts the walker reaches it and that the scan matches,
  and removes it. That test is why the file is `async: false`.

After the deletion, a rerun of the same gitleaks invocation over the tree finds
nothing outside `deps/` and `_build/`.

---

## 5. The evidence itself

Every file this unit wrote under `docs/evidence/v1/phase-09/` and under Pro's
`docs/evidence/v1/phase-09/` was scanned with the same three patterns:

```
files with credential shapes: 0
```

The proof run's evidence records **test-mode object ids** (`acct_`, `cus_`,
`pi_`, `ch_`, `re_`, `sub_`, `price_`, `prod_`, `mtr_`, `in_`, `clock_`), which
the owner authorisation records as safe to write down, and the pinned
`STRIPE_API_VERSION`. It records **no key**, **no `whsec_` value and no part of
one**, and **no real email address**: the only address in the run is
`<run-id>@example.com`.

No screenshot was taken by this unit.

## 6. Controls

`tmp/v1/09d/controls-guards.sh`, control C2: a key-shaped string, assembled the
same way, appended to `README.md`.

```
PASS  C2-key-in-tree: the instrument failed when the defect was planted (rc=2)
[restored] README.md (e6c7e43d4efac29b)
```

The restore is verified by sha256 rather than assumed, and `git checkout --` is
never used.
