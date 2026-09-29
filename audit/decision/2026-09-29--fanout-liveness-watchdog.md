## 2026-09-29 — Self-reported checkpoint ledger, not dispatcher polling -- verified no polling primitive exists

**Decision:** ship `bin/progress-ledger.py` as a self-reported checkpoint ledger + scheduled staleness
check, NOT a dispatcher-side liveness poll, because the latter does not exist as a real capability today.

**Rationale:** the human's stated failure mode (sub-supervisor stalls/dies *before* `verify-gate`) cannot
be detected by anything the dispatcher can observe from outside — verified directly against Claude Code's
documented Agent-tool behavior before writing any code: no `ListAgents`-equivalent tracks individual
Agent-tool background invocations, there is no separate task registry for them, and a silently-crashed
subagent produces the exact same "no notification yet" signal as one still slowly working. Only `maxTurns`
is enforced, with no wall-clock timeout. Given that hard constraint, self-reporting plus a
`ScheduleWakeup`-driven periodic recheck is the only mechanism that can exist — not a design preference.

**Explicitly declined, with reasoning:**
- No dispatcher-side polling of anything (`herdr agent get`, a hypothetical Agent-tool status API) — this
  was the original sketch, corrected mid-flight after verification rather than shipped on an assumption.
- No claim to real-time/instant liveness detection anywhere in code or docs — every surface (SKILL.md,
  ARCHITECTURE.md, the primitive's own CLI output) states plainly that this is scheduled detection on
  whatever cadence the dispatcher chooses, not a proof of crash vs. merely-slow.
- No auto-restart, no auto-`--steal`, no automated cleanup on a `stale` hit — matches this repo's existing
  `SM_STUCK_NEED_HUMAN` posture exactly: relay to the human verbatim, never attempt to resolve it.
- No second new ledger for Task B's later "batch readiness" need — folded into the same `{task-id, phase,
  ts}` primitive as just another phase value, since building two near-identical fcntl-locked JSONL ledgers
  for two closely-related concerns would have been pure duplication.
- No change to `claim-ledger.py`'s own schema/event types (a live alternative some plan-committee members
  considered) — a new event type there would trip every old copy's parser into `_BAD` corruption warnings;
  a dedicated sibling primitive avoids that entirely.

**Checker findings, both real, both fixed via loop-back (never fixed inline by the supervisor):**
1. Round 1: `stale` crashed on a non-parseable `ts` string instead of tolerating it — the exact failure
   mode this primitive exists to prevent.
2. Round 2: the whole-ledger scan mode silently dropped a task-id whose only checkpoint had a malformed
   timestamp, instead of reporting it as needing attention — arguably worse than a crash, since it fails
   silently in the primary intended usage pattern.
Round 3: clean, including checker-driven adversarial probes (24 concurrent writers; confirming the round-2
fix didn't introduce a new false-positive against an unrelated malformed row).

**Gate:** PASS at `94884ef773666243babd9c6f1169e4fcc42daf3c`.

**Hold:** genuine human "yes" answer (`1a3e9bd2`), SHA-bound, no self-answer.

**Residual/deferred (out of scope for this task, named for later):** automatic recovery (auto-restart,
auto-reap) of a flagged stale sub-supervisor is still not built — detection-and-surface only, by design,
matching `claim-ledger.py`'s own existing disclosure style for its "no liveness/reaping" limitation. Task B
(batch-hold N=10 scaling) is the next task, reusing this same primitive's terminal `verify_gate_pass`
phase as its batch-readiness signal.
