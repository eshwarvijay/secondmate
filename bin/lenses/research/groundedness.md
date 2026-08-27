# Research sub-lens: groundedness

Every load-bearing factual claim must trace to evidence you can point at — the actual library/spec/source,
official docs, or a test that exercises the real behavior. Treat model memory as an unreviewed witness, never
authoritative. A load-bearing hallucination = `fail`.

- **Hallucinated surface area** — does the change call a method, class, constant, module, CLI flag, config
  key, or endpoint that does not exist in the named library/version? Cross-check against the dependency's
  real source, type stubs, or docs — not against what such an API "should" look like. Plausible naming
  (`client.fetch_all()`, `--no-verify-ssl`, a `retries=` kwarg) is the classic tell. If you can't find the
  symbol, say so and label it.
- **Version / compatibility assumptions** — does the code assume a behavior, default, or signature from a
  different version than the repo pins? Check the lockfile/manifest for the real version, then check whether
  the assumed behavior holds for THAT version. Silent version drift is a fail-class error.
- **Made-up flags / options / parameters** — confirm each CLI flag, kwarg, env var, or config field against
  the real interface. A flag that reads correctly but isn't in the parser is a fabricated fact.
- **Confident-but-unchecked facts** — assertions stated as certainty ("this is idempotent", "the API returns
  sorted results", "encoding is always UTF-8") with no demonstrating evidence. Confidence is not evidence;
  flag the claim and note what would verify it.
- **Magic constants** — timeouts, retry counts, buffer sizes, thresholds. Traceable to a spec/convention/
  rationale, or picked because it "felt right"?

If you couldn't verify a claim read-only (no network, dep source not vendored, symbol unresolved), it's
SUSPECTED, not CONFIRMED, and not a clean pass — say the coverage was limited.
