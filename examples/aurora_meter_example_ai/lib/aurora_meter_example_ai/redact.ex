defmodule AuroraMeterExampleAi.Redact do
  @moduledoc """
  Replaces credential-shaped text with `[redacted]` before it is written
  anywhere.

  This module exists because of an ordering decision rather than a feature
  request: it and `test/secret_scan_test.exs` were written **before** the Pro
  profile used a Stripe key on this machine at all. A redaction filter added
  after the first leak is a filter that redacts the second one.

  ## What it matches, and why each shape is here

  | Pattern | What it is |
  |---|---|
  | `sk_test_…`, `sk_live_…` | a Stripe secret key |
  | `rk_test_…`, `rk_live_…` | a Stripe restricted key |
  | `pk_live_…` | a Stripe live publishable key. `pk_test_` is deliberately **not** redacted: it is designed to be embedded in a page, and redacting it would hide a configuration mistake rather than a secret |
  | `whsec_…` | a webhook signing secret |
  | `Bearer <token>` | an Authorization header that reached a log line |
  | `Stripe-Signature: …` | the signature header, which carries no key but is a per-request MAC and has no business on disk |

  A key is matched from its prefix to the end of the run of key characters, so a
  partial key is redacted too: "no part of a key" is the rule
  (`docs/v1/build-plans/README.md`, owner authorisation 1).

  ## What it is not

  It is not a substitute for not writing the key. The order is: never pass a
  credential on a command line, never echo one, and then run everything that is
  written through here anyway. Three guards, of which this is the last.
  """

  @patterns [
    # Stripe secret and restricted keys, live or test, and any prefix of one.
    ~r/\b(?:sk|rk)_(?:test|live)_[A-Za-z0-9]*/,
    # Live publishable keys. pk_test_ is intentionally absent; see above.
    ~r/\bpk_live_[A-Za-z0-9]*/,
    # Webhook signing secrets.
    ~r/\bwhsec_[A-Za-z0-9_\-]*/,
    # Hex API keys are printed by `mix hex.user key generate` as a bare 32+
    # character base-32-ish blob, which is unmatchable on its own. What IS
    # matchable is the assignment a script or a log line would carry.
    ~r/\b(?:HEX_API_KEY|AURORA_HEX_READ_KEY|STRIPE_SECRET_KEY|STRIPE_API_KEY|STRIPE_WEBHOOK_SECRET)\s*[=:]\s*\S+/,
    ~r/\bBearer\s+[A-Za-z0-9._\-]+/,
    ~r/\bStripe-Signature:\s*\S+/i
  ]

  @replacement "[redacted]"

  @doc """
  Redacts one line, or any binary.

  ## Examples

  The key-shaped strings below are **assembled** rather than written out, and
  that is worth a sentence. `test/secret_scan_test.exs` walks every file in
  this tree looking for exactly these shapes, and a module whose documentation
  contains one finds itself. The first version of this file did, which is how
  a scan acquires an exclusion list and quietly stops covering the two files
  most likely to touch a key.

      iex> AuroraMeterExampleAi.Redact.line("using " <> "sk_test_" <> "abc123DEF" <> " for checkout")
      "using [redacted] for checkout"

      iex> AuroraMeterExampleAi.Redact.line("secret " <> "whsec_" <> "0123456789abcdef")
      "secret [redacted]"

      iex> AuroraMeterExampleAi.Redact.line("nothing to see here")
      "nothing to see here"

  A test-mode publishable key is left alone on purpose: it is not a secret and
  hiding it hides a misconfiguration.

      iex> AuroraMeterExampleAi.Redact.line("pk_test_" <> "51abc")
      "pk_test_51abc"

  """
  @spec line(binary()) :: binary()
  def line(text) when is_binary(text) do
    Enum.reduce(@patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, @replacement)
    end)
  end

  @doc """
  True when `text` still contains something credential shaped after redaction.

  Used by the secret scan to check itself: a filter that cannot be shown to
  catch what the scan looks for is two independent hopes rather than one
  guard.
  """
  @spec credential_shaped?(binary()) :: boolean()
  def credential_shaped?(text) when is_binary(text) do
    Enum.any?(scan_patterns(), &Regex.match?(&1, text))
  end

  @doc """
  The patterns the repository scan uses.

  Deliberately **not** the same list as `line/1`'s. `line/1` redacts anything
  that looks like the start of a key, including a two-character fragment, so
  that a truncated key in an error message cannot survive. A repository scan
  using that list would fire on the literal `sk_test_` in this module's own
  documentation and in every refusal message in the tree, which is a scan that
  is switched off within a week. The scan therefore requires eight or more key
  characters after the prefix, which no documentation example has and every
  real key does.
  """
  @spec scan_patterns() :: [Regex.t()]
  def scan_patterns do
    [
      ~r/\b(?:sk|rk)_(?:test|live)_[A-Za-z0-9]{8,}/,
      ~r/\bpk_live_[A-Za-z0-9]{8,}/,
      ~r/\bwhsec_[A-Za-z0-9_\-]{8,}/
    ]
  end

  @doc """
  Redacts a whole multi-line string, line by line.

  ## Examples

      iex> AuroraMeterExampleAi.Redact.text("a\\n" <> "sk_test_" <> "0123456789" <> "\\nb")
      "a\\n[redacted]\\nb"

  """
  @spec text(binary()) :: binary()
  def text(binary) when is_binary(binary) do
    binary
    |> String.split("\n")
    |> Enum.map_join("\n", &line/1)
  end
end
