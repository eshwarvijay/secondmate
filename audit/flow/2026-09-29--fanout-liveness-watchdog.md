## 2026-09-29 — progress-ledger.py: self-reported checkpoints + scheduled staleness detection for fan-out (Task A of 2)

**Origin:** human flagged two problems with secondmate's fan-out pattern as one combined ask — the N=2 cap
(rationale was human attention, not concurrency-safety) blocking ~10-way scaling, and sub-supervisors "not
maintaining the loop end to end until it is pushed to github". Ran the full plan committee (adhd in-process
+ 6-model `plan-committee.sh` against a fresh task-scoped `--out-dir`) against both together, then
escalated two genuine open questions via `AskUserQuestion` rather than inventing answers: (1) where exactly
the observed failure occurs — answer: **before `verify-gate`, not after** (this repo's own audit trail had
zero recorded failures and one recorded success, so the premise needed grounding before designing around
it); (2) whether to drop `hold.py`'s per-task `--sha` 1:1 anti-reattach binding for a consolidated hold —
answer: **no, extend it to a structured `{task-id: checked-sha}` list instead.**

adhd's non-negotiable finding (human-confirmed by the failure-mode answer): batch-hold alone does not fix a
pre-`verify-gate` death, since that's a "who owns the merge" fix, not a liveness fix. Split into two
sequential maker tasks — Task A (this one, the actual bug fix) and Task B (batch-hold N=10 scaling, queued
next, dispatched to a fresh sub-agent-supervisor once this merged).

**Critical mid-flight correction:** the original Task A sketch (dispatcher polls `herdr agent get
<name>` for each fanned-out sub-supervisor) was wrong — sub-agent-supervisors are spawned via the plain
Agent tool, not herdr panes (herdr only appears *inside* a sub-supervisor's own maker/checker loop).
Verified directly against Claude Code's documented behavior via the `claude-code-guide` agent before
writing the maker prompt: **there is no way for a dispatcher to poll an Agent-tool background subagent's
liveness from outside** — a silent pre-notification death is indistinguishable from "still working," a
hard platform limit. Corrected the plan to a self-reported checkpoint ledger + `ScheduleWakeup`-driven
scheduled recheck, and folded what would have been two separate new primitives (Task A's liveness ledger,
Task B's batch-readiness ledger) into one shared `bin/progress-ledger.py`, since a "reached verify-gate
PASS" record is just another phase row in the same ledger.

**Maker:** Claude (complex route — new primitive design, SKILL.md/ARCHITECTURE prose rewrite requiring
judgment). Worktree `sm/fanout-liveness-watchdog`.

**Rounds:** 3.
- Round 1: checker found `stale` crashes with an uncaught `ValueError` on a non-parseable `ts` string
  instead of tolerating it per this file's own established convention — the exact failure mode the
  primitive exists to prevent (a corrupted ledger silently disabling the only staleness signal).
- Round 2 (after fixing round 1): checker found a second, arguably worse defect — the whole-ledger `stale`
  scan (no `--task-id` given) derived its candidate set only from validly-folded rows, so a task-id whose
  *sole* checkpoint had a malformed timestamp silently vanished from the scan instead of being reported as
  `no_progress_recorded`. Both fixed via loop-back to the same maker, never fixed inline by the supervisor.
- Round 3: clean pass, zero findings. Checker's own adversarial probes: 24 concurrent `record` writers (no
  lost/corrupted rows), and confirmed the round-2 fix didn't introduce a new false-positive (an unrelated
  malformed row no longer wrongly suppresses a real valid checkpoint elsewhere in the ledger).

**Gate:** `verify-gate.sh` PASS at `94884ef773666243babd9c6f1169e4fcc42daf3c` (clean, non-empty vs main,
checker-current, `progress-ledger.py selfcheck` green).

**Hold → merge → teardown:** genuine human "yes", SHA-bound. Merged via `merge-sequencer.sh` as `b6f6fbf5`
(pushed to origin). Worktree/workspace removed, branch deleted, `teardown-check.sh` confirmed clean on all
four axes (worktree/branch/herdr/claim).

**Deliberately deferred (named, not silently dropped):** no plugin.json version bump (purely additive
feature, no existing behavior changed — same posture as the earlier claim-ledger scope+operation task).
Task B (batch-hold N=10 scaling) is queued next, to be dispatched as a fresh sub-agent-supervisor per the
human's explicit N=1-delegation request, now that this primitive exists on `main` for it to build on.
