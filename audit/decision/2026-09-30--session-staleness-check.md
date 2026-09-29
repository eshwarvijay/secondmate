## 2026-09-30 — Advisory-only SessionStart staleness surfacing; reuse doctor.sh detection unchanged

Background: `bin/doctor.sh` already had a working plugin-staleness detector
(`_detect_secondmate_status`/`_detect_secondmate_staleness`, comparing `installed_plugins.json`'s SHA/version
for the secondmate entry against the marketplace checkout's `plugin.json`) but it was only ever exercised when
a human manually ran `/secondmate-doctor` or `doctor.sh`. Earlier the same day, this exact session had run an
entire multi-task stretch off a stale cached plugin version before a human noticed — a live instance of the gap
a 6-model + adhd plan-committee audit flagged as this repo's own SessionStart hooks never checking their own
staleness.

Decision 1 — exposure mechanism: reuse `_detect_secondmate_status` via a new `doctor.sh --staleness-json`
early-exit flag (prints `{"status":..., "details":...}`, exits 0, never reaches the lock/heal/table-rendering
machinery) rather than sourcing the function into another script or re-deriving the SHA/version comparison.
Both the maker and the independent `adhd` ideation fork converged on this same shape unprompted — accepted as
the correct call: it keeps the SHA/version diff logic in exactly one place (the constraint the human's brief
required), costs ~10 lines, and matches this file's own existing idiom of self-invoking as a subprocess for
`--json`/`--selfcheck`.

Decision 2 — new sibling hook vs. extending `session-activate.sh`: chose a new `bin/session-staleness.sh`,
modeled byte-for-byte on the existing `bin/session-holds.sh` sibling-hook pattern (own `--selfcheck`, silent
when nothing to report, always exits 0), registered as a third `hooks/hooks.json` `SessionStart` entry — rather
than folding staleness text into `session-activate.sh`'s static banner. Accepted: `session-activate.sh` is
static invariant text with its own selfcheck asserting exact banner strings; wiring in a dynamic,
fixture-dependent check would have made that selfcheck fragile and mixed two different concerns (static
supervisor doctrine vs. live environment probing) in one file.

Decision 3 (flagged, not overridden) — which statuses print: the shipped hook surfaces an advisory on ANY
non-`ok` status, including `unknown`/`missing`. The parallel `adhd` fork recommended a narrower allow-list
(silent on `unknown`/`missing`, print only on `stale`/`silent_drift`/`reload_pending`) to avoid nagging
non-marketplace installs or transient read hiccups. The human's task brief did not mandate either shape, the
checker found no defect or safety issue with the broader choice (confirmed it never executes untrusted JSON
field content as shell, always exits 0, never heals regardless of status), and this was surfaced to the human
in the hold-adjacent report before merge; the human's `yes` answer did not ask to narrow it, so it shipped
unchanged. Recorded here as a considered, disclosed trade-off, not an overlooked one.

Checker findings: none. Verdict `pass` on round 1, no fix-loop needed. Verified boundary probes included:
shell-injection attempts via crafted SHA/version fields (rendered as inert printf data, never executed),
malformed JSON handling, and confirmation that `--staleness-json` and the hook both bail before doctor.sh's
lock/heal code path.

Gate auto-approved: `verify-gate.sh` PASS on the exact checked sha, no escalation needed (checker-current, tests
green, clean non-empty diff).

Hold: `b099cfaf` answered `yes` by a genuine human (relayed via the dispatching coordinator; independently
re-verified against the raw `decisions.jsonl` ledger record — `{"ev":"answer","id":"b099cfaf","a":"yes"}` —
before acting on it, rather than trusting the relay text alone). Merged unchanged as instructed.

Lessons tagged this task (direct, task-specific grounding only):
- `testing/mutation-test-your-tests` -> helpful (maker explicitly mutation-tested its own selfcheck: flipped the
  real `stale` branch to `ok` inside `_detect_secondmate_status`, confirmed the selfcheck then failed, restored,
  confirmed it passed again).
- `workflow/commit-before-done` -> helpful (maker literally ran `git commit` and confirmed a clean tree before
  replying DONE; no uncommitted-changes-at-DONE recurrence).
- `workflow/stay-in-literal-scope` -> helpful (maker noticed the live environment showing `reload_pending` from
  an unrelated prior heal, explicitly called it out in its DONE summary as "noticed but left untouched (out of
  scope)" instead of fixing it inline).
- `debugging/avoid-ad-hoc-debug-loops` -> left untagged (no debugging scenario involving loops/symlinks/recursion
  arose this task; no grounds either way).
