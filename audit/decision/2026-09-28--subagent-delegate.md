## 2026-09-28 — Widen fan-out trigger to N=1, decline security/config over-engineering

**Decision:** widen `SKILL.md`'s "Fan-out to concurrent sub-supervisors (hard-capped at 2)" section into
"Fan-out to fresh sub-agent-supervisors (1 or 2, hard-capped at 2)" -- an explicit human ask to delegate a
*single* task's whole supervisor loop to a fresh sub-agent is now an equally valid, documented trigger,
alongside the pre-existing 2-concurrent-independent-tasks trigger. Mechanically identical either way: one
Agent-tool call, one tool-use block for the single-task case (vs. up to two for the concurrent case), the
spawned sub-agent claims/triages/routes/checks/gates/holds/merges exactly as the existing mechanics
already specified for N=2 -- none of steps (a)-(g) needed editing.

**Explicitly declined, with reasoning (not silently dropped):**
- No new `SM_*` environment variable / configurable N-threshold -- there is no technical N-limiting
  parameter anywhere in the codebase to control; the "cap" was pure dispatcher-level prose.
- No auto-delegation / heuristic "this should be delegated" detection -- explicit human ask only, per the
  task's own stated constraint and to avoid ordinary single-task work silently fanning out.
- No ACL / ownership-binding / ID-size-limit layer on `claim-ledger.py` (one planner, mistral-large3,
  proposed this under a security lens) -- this is a single-operator local CLI tool with no multi-tenant
  session model anywhere in the codebase; `claim-ledger.py --owner` is documented by design as a
  human-readable label, not real proof. Adding auth machinery here solves a problem this deployment
  doesn't have.
- No reaper/TTL for stale claims -- already an explicitly named, deliberately deferred gap in
  `ARCHITECTURE.md`; not reopened by this fix.
- No raising of the existing "at most 2 Agent-tool blocks per dispatch call" ceiling, and no change to
  what the 2-concurrent-task trigger means -- both preserved exactly as documented before this change.

**Checker findings:** none in the final (4th) invocation. The first three invocations' apparent findings
were all supervisor-side scripting artifacts (checker reviewing the wrong tree / an empty diff), not real
findings about the change -- explicitly called out and discarded rather than treated as real signal.

**Gate:** auto-approved (clean tree, non-empty diff, checker-current SHA) -- no escalation needed.

**Hold:** genuine human "yes" answer, SHA-bound to `090b22c8`, no self-answer.

**Residual gap surfaced but NOT fixed in this task (out of scope, noted for later):** `launch-checker.sh`'s
`--repo` flag only feeds its own internal diff-text computation and never `cd`s the checker's actual tool
calls into that directory -- the documented "Checker pane" recipe in both `SKILL.md` and this task's own
execution assumed a herdr pane split off a worktree's root_pane inherits that worktree's cwd, which it did
not (`herdr pane get` showed the split pane's cwd was the *primary* checkout, not the worktree). Worked
around here with an explicit `cd` as the first line of the checker script. This is a real gap in the
documented pattern itself and should be fixed in `SKILL.md`'s checker-pane recipe as a separate task.
