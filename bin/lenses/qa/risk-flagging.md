# QA sub-lens: risk-flagging

Some diffs carry blast radius far beyond their line count. When the change touches any class below, RAISE the
bar: partial coverage that would pass elsewhere is a finding here, and a missing negative/abuse test is
CONFIRMED, not SUSPECTED. A high-risk change with thin tests can be `fail` even if the code reads fine.

- **Authentication / authorization** — login, tokens, sessions, permission checks, role boundaries. Demand
  tests for the *denied* path and expiry/tamper, not just success.
- **Data migrations / schema changes** — demand up+down/rollback tests, a large-dataset/batching case, and a
  "run twice" idempotency test.
- **Money / billing / quantities** — pricing, proration, tax, currency, rounding, unit conversion. Demand
  rounding-boundary and negative/zero-amount tests; a money path with no rounding assertion is a finding.
- **Public API / library surface / wire formats** — demand backward-compat and contract tests pinning the
  exact response shape.
- **PII / security / crypto / secrets** — demand tests that secrets aren't logged/leaked and that malformed /
  unauthorized / injection input is rejected.
- **Deletes / destructive ops / external side effects** — demand a test proving the blast radius is bounded
  (right rows only) and a dry-run/guard test.

For a high-risk change with adequate tests, say so explicitly.
