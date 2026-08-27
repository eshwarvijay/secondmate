# QA sub-lens: coverage

Do NOT accept "coverage looks good." Turn coverage into hard YES/NO questions for THIS change; answer each
for the paths the diff actually introduces or touches. Any NO on a reachable path is a finding; a critical
path untested = `fail`.

- **Happy path** — is the primary success case asserted on its real output? YES/NO
- **Boundary / edge** — 0, 1, max, off-by-one, empty vs. one vs. many, first/last, overflow, truncation,
  timezone/DST, float rounding? YES/NO
- **Error paths** — is every `raise`/`throw`/error-return and every `catch`/`except` branch exercised,
  asserting the *specific* error, not just "it threw"? YES/NO
- **Null / empty / missing** — null, `None`, `""`, `[]`, `{}`, absent key, missing optional arg, unset env? YES/NO
- **Concurrency** — if the change touches shared state, locks, async, ordering, or retries: any test for
  interleaving, double-invocation, or a race window? (Usually NO → SUSPECTED unless provably single-threaded.) YES/NO
- **Idempotency** — for writes/upserts/deletes/publishes/migrations: does calling twice give the same result,
  and is that asserted? YES/NO
- **Backward-compat / regression** — for changed signatures, serialized formats, schemas, API responses,
  config keys: is old data / an old caller still tested? YES/NO
- **Reproduced bug → regression test.** If this is a bug fix, there MUST be a test that reproduces the
  original failure (fails without the fix). A fix with no reproduction test is a CONFIRMED gap, however
  obviously correct the code looks.

Be specific: not "needs more tests" but "the `except TimeoutError` branch at `client.py:88` has no test; add
one that forces a timeout and asserts the retry count."
