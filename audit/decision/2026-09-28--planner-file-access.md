## 2026-09-28 — Reuse checker's --exclude-tools pattern, decline new sandbox machinery

**Decision:** replace `--no-tools` with `--exclude-tools edit,write` for all 6 plan-committee planner
invocations (main + retry), reusing the exact flag already proven safe for the checker in
`launch-checker.sh` rather than inventing a new access-control mechanism. Bump `SM_COMMITTEE_TIMEOUT`
default 300->600 to match realistic tool-loop durations. No changes to `committee-output.py` or
`run-round.sh` -- both verified compatible with multi-turn tool-use transcripts by reading them directly,
not assumed.

**Explicitly declined, with reasoning (mistral-large3's security-lens proposals):**
- A new `SM_COMMITTEE_READONLY` env var as a feature-flag gate on top of `--exclude-tools` -- redundant;
  the flag itself is already the gate.
- Path deny-lists ("compiled into pi's tool whitelisting") for `/etc`, `~/.ssh`, `.env`, etc. -- this is a
  single-operator local CLI tool; a planner's Bash access already carries the same trust level the
  operator's own shell has. `launch-checker.sh` has carried the identical exposure without incident. Adding
  an access-control layer here defends against a threat model (an adversarial or untrusted planner) that
  doesn't exist in this deployment.
- Output content-scanning/redaction in `committee-output.py` for "high-entropy strings" or long verbatim
  quotes -- same reasoning; also would have required real code changes to a function verified to need none.
  All three explicitly ruled out-of-scope by the task's own stated constraint before the maker ever started,
  not silently dropped after the fact.

**Checker findings:** none. Verified beyond the diff itself -- a fake-`pi` fixture built specifically to
exercise the real launch/retry code path, and full end-to-end reads of two labels' actual resulting prompt
text, per explicit instruction not to trust the diff summary alone.

**Gate:** auto-approved. **Hold:** genuine human "yes," SHA-bound, no self-answer.

**Evidence this fix targets a real, recurring problem, not a one-off:** deepseek-r1 fabricated fake quoted
"evidence" from a file/function it never read on two separate, independent occasions -- once in an earlier
task (a YAML file) and again during the very committee run that planned this fix (a fabricated
implementation of `committee-output.py`'s `extract()`). Both instances are documented with the real,
correct implementation alongside the fabrication for contrast, in case the pattern recurs and this becomes
useful precedent for diagnosing it again.
