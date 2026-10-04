## 2026-10-04 — use-default-todo-tool: generic check-then-use task-tracking tool wording for sub-agent-supervisors

## 2026-10-04 — use-default-todo-tool: generic check-then-use task-tracking tool wording for sub-agent-supervisors

Solo dispatch, `ship`/`full` rigor. Plan Committee: 0a (adhd) skipped per CLAUDE.md's skip criteria —
closed-form wording-precision fix to one existing paragraph, not an open-ended design question; 0b ran
all 6 planners (deepseek-r1, glm5, kimi-k3, mistral-large3, qwen3-80b, qwen3-coder) via
`plan-committee.sh --out-dir .secondmate/planning/use-default-todo-tool` (top-level planning dir had
unmarked output from a sibling task, so a dedicated out-dir was used); 0c synthesized all probes from
repo evidence (grep for `TodoWrite` references, read of `docs/ARCHITECTURE.md` and the prior
`sub-supervisor-todo-list` audit decision entry) with zero business/product escalations needed.

Maker: Claude, routed per step 0d as "complex" (nuanced wording that must stay correct across three
mutually exclusive tool-availability states without hardcoding one, plus a secondary doc-sync edit).
Ran in an isolated herdr worktree (`sm/use-default-todo-tool`), one round, no fix rounds needed.
Edited `skills/secondmate/SKILL.md`'s "## The loop" paragraph and `docs/ARCHITECTURE.md`'s short
restatement (~lines 85-90) to the same generic check-then-use framing. Committed as `2a48ed7`.
Verified via git-diff scope check + full re-read (no markdown lint/test exists in this repo for
SKILL.md/ARCHITECTURE.md content).

Checker: cross-model (`global.openai.gpt-5.6-terra`) in a visible herdr pane (strict rule under
HERDR_ENV=1). One round. Verdict: pass, 0 findings, 4/4 lenses covered (tool-agnostic-correctness,
scope-boundary-preservation, documentation-consistency, change-scope-invariants). verify-gate: PASS
at checked-sha `2a48ed7d821c1f1343671955518d81de619957a7`.

Human hold: opened without `--sha` binding (a process gap on my part — should have passed `--sha` at
hold-creation time; the question text named the sha explicitly instead, and no sha-mismatch rejection
occurred since the hold recorded no sha to check against). Answered "yes" ~3 minutes after opening —
independently re-verified in the raw `decisions.jsonl` ledger (not taken on the coordinator's word)
before merging.

Integrated: `bin/merge-sequencer.sh` merged `sm/use-default-todo-tool` → `main` as `55ce09d`, pushed to
origin. No `plugin.json` version bump (no cache-drift issue here, unlike precedent commit 6abe270); no
`README.md` change needed (confirmed via grep — it had no `TodoWrite`/task-tool reference to begin
with). Teardown: worktree/workspace/branch/claim all confirmed clean via `teardown-check.sh`.
