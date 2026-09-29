## 2026-09-30 — batch-hold-scaling: extend consolidated batch hold to N=10 concurrent sub-supervisors

## Fan-out context
Delegated as a single-task sub-agent-supervisor fan-out (explicit human "delegate a single task" trigger,
per `skills/secondmate/SKILL.md`'s "Fan-out to fresh sub-agent-supervisors" section). Plan committee
(adhd + 6-model `plan-committee.sh`) had already run at the top level before delegation; this
sub-supervisor skipped steps 0a-0c and received an already-resolved spec directly (Task B of
`.secondmate/planning/fanout-batch-hold-redesign/CONSOLIDATED.md`).

## Maker routing
Routed to a **Claude maker** (agent `sm-batch-hold-scaling`, herdr pane w30:p1), per the SKILL.md routing
rubric — judged complex: touches `bin/hold.py`'s on-disk schema, adds a new `bin/dispatch-report.py` tag,
and requires a coordinated multi-file doc/hook rewrite (SKILL.md, ARCHITECTURE.md, README.md,
`plugin.json`, two SessionStart hooks).

## Checker
Cross-model checker (`global.openai.gpt-5.6-terra` via `bin/launch-checker.sh`), run in a **visible herdr
pane** (w30:p2) per the strict HERDR_ENV=1 rule — no headless exception taken. Lenses injected every
round: `qa/coverage`, `qa/risk-flagging`, `redteam/access-control` (chosen for: new/changed behavior
coverage; the hold/merge gate being high-blast-radius; and the explicit "never let a passing check
substitute for the human hold" invariant reading as an access-control-bypass class of risk). All 3 lenses
confirmed present in `lens_coverage` every round.

## Round count and outcome
4 rounds to a clean PASS:
- Round 1: FAIL, 6 findings (missing verdict-artifact validation on batch entries, thin/incomplete digest,
  N=10 cap unenforced on `--entries-file`, silent dedup corrupting the batch answer's audit record,
  no way to distinguish this batch's ready rows from an unrelated batch/solo task after a dispatcher
  restart, two modified hooks shipped with no real `--selfcheck`).
- Round 2: FAIL, 2 findings (the round-1 `--batch-id` fix didn't structurally stop two unrelated task-ids
  from colliding on an identical batch-id string; `hold.py`'s envelope validation accepted any dict with a
  `verdict` key regardless of shape).
- Round 3: FAIL, 1 finding (README/ARCHITECTURE/SKILL.md made an absolute claim — "never folds unrelated
  work" / "exact same set" — that contradicted the honestly-documented residual limitation written
  elsewhere in the same diff; doc-only fix, no code change).
- Round 4: PASS, empty findings, full accumulated diff reviewed against the original pre-task base.

Independently re-verified myself after every round (never trusted the maker's self-report alone): ran
`--selfcheck` on every touched script (`bin/hold.py`, `bin/progress-ledger.py`, `bin/dispatch-report.py`,
`bin/verdict.py`, `bin/session-activate.sh`, `bin/session-holds.sh`) and confirmed each verdict
deterministically via `bin/verdict.py` rather than reading checker prose.

## Gate and hold
`bin/verify-gate.sh` PASS at `c63f2bcd5e3efdba11574974a3cef978700a91ec` (clean, non-empty vs main,
checker-current). Opened my own consolidated-merge hold (`bin/hold.py hold --task batch-hold-scaling --sha
c63f2bcd5e3efdba11574974a3cef978700a91ec`, id `4899dfd4`) and waited — never self-answered. A genuine human
answered `approve`, SHA-bound to the same checked-sha, relayed by the dispatcher and independently
re-verified by me directly against `decisions.jsonl` before acting on it.

## Integration and teardown
`bin/merge-sequencer.sh` merged `sm/batch-hold-scaling` -> `main` as
`750d164a487a77c3621a2f4beb9e0303b20c02f3` (pushed to origin). Teardown: herdr worktree/workspace removed,
branch `sm/batch-hold-scaling` deleted, claim released (`bin/claim-ledger.py release`), confirmed clean via
`bin/teardown-check.sh` (`worktree/branch/herdr/claim: clean`).
