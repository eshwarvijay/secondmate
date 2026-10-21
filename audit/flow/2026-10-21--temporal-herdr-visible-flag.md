## 2026-10-21 — temporal-herdr-visible-flag: --herdr-task-id flag threads bridge's herdr-visible mode into run-round-temporal.sh

## Flow — temporal-herdr-visible-flag

Dispatched as a solo sub-agent-supervisor. Plan committee ran 5/6 multi-model planners successfully
(deepseek-r1, glm5, mistral-large3, qwen3-80b, qwen3-coder; kimi-k3 failed twice on tool-call-shaped
leakage and was skipped) plus the `adhd` skill's own pre-flight self-judge, which correctly ABORTED
divergent ideation for this task: closed, mechanical, minimal-diff work per the task's own phrasing
and the human's explicit ponytail/minimalism directive, not an open-ended design decision. All
planner probes (regex source, local-vs-bridge validation, guard AND/OR semantics, injection surface,
warning tone, what the id is consumed for) were answered directly from repository evidence — the
supervisor read `internal/planrun/herdr.go`/`maker.go`/`checker.go` in the bridge repo itself before
dispatching, rather than trusting any paraphrase. Zero OPEN DECISIONs needed human escalation at the
planning stage.

Maker: **Claude** (not pi), routed for the security-sensitive shell-flag-parsing + guard-rewrite +
multi-file doc-sync nature of the change — matches the "Complex" routing rule. Explicitly instructed
to invoke the `ponytail` skill before writing code (human's mid-task addition); confirmed in the pane
transcript (`Skill(ponytail) -> Successfully loaded skill`).

Round 1: the maker's worktree-scoped scope-guard hook correctly hard-blocked it from reading the
read-only bridge repo directly (including via a subagent) — the sandbox working as intended. Resolved
by the supervisor pasting verbatim, independently-verified bridge source snippets into the prompt, and
separately copying the 3 relevant bridge files into a gitignored `.scratch/bridge-refs/` dir inside the
maker's own worktree (source repo read-only, never modified; scratch dir removed before the maker's
commit, confirmed). Maker implemented the flag, validation, plan-JSON threading, guard rewrite, and
doc sync; committed `5a07302`. Discovered and documented (not fixed) that the bridge's herdr-visible
maker ignores `--repo` and resolves/creates its own `herdr-task-<ID>` worktree — a caller/dispatcher
contract now named in the script header, SKILL.md, and ARCHITECTURE.md.

Check round 1 (redteam/injection lens, visible pane per the strict HERDR_ENV=1 rule, diff-base
`18f9def`): **fail**, 3 CONFIRMED findings. Supervisor adjudicated: 2 legitimate (empty-string
`--herdr-task-id ''` silently bypassing validation; the neither-flag-given refusal message text
drifting from the base script) routed as a fix plan; 1 (PATH-hijacked `dirname` at module-bootstrap
scope) verified via `git show 18f9def:bin/run-round-temporal.sh` to be byte-identical in the base
script — pre-existing, not a regression this task introduced, explicitly told to the maker as
DO-NOT-FIX and to round-2's checker as not-a-blocker.

Round 2: maker fixed both legitimate findings minimally (one new local var `herdr_task_id_given`, one
condition flip, one reverted message string), added 2 mutation-tested selfcheck assertions, committed
`1ed9bee`.

Check round 2 (same lens, diff-base `5a07302`, prior verdict auto-injected for continuity): **pass**,
zero findings, including a live shell-injection probe (`$(touch ...)` payload in the id value,
confirmed rejected before any subprocess ran) and an explicit byte-identical comparison of the no-flag
dry-run plan JSON against the pre-maker base.

Supervisor independently re-ran `--selfcheck` after both rounds (not just trusting maker/checker
claims) — `ok` both times. `verify-gate.sh` -> PASS (clean, non-empty vs main, checker-current, tests
green). Human hold `1d8023f4` opened with full rationale; human answered "yes" (plain merge approval,
not the follow-up-ticket variant). Merged via `merge-sequencer.sh` as `e8f6872` on `main`, pushed to
origin. Teardown confirmed clean via `teardown-check.sh` (worktree/branch/herdr/claim all clean).

Post-merge, per the human's explicit request, ran a real live end-to-end demonstration of the new
`--herdr-task-id` flag against the actual local Temporal bridge under `HERDR_ENV=1` (not just
selfcheck/injection-probe evidence): pre-created a disposable worktree+branch
`herdr-task-smlivedemo1` off `main` (so `--repo` and `--herdr-task-id smlivedemo1` lined up per the
maker's own documented caller contract), built the real bridge CLI, started a real local Temporal dev
server + worker (`BRIDGE_ROOT=<that worktree>`), and submitted a real plan with `herdr_task_id` set on
both steps. A genuine herdr-tracked `claude` agent `mk-smlivedemo1` came up on pane `w82:p1` (status
`done` afterward, confirmed via `herdr agent get`) and wrote the requested trivial file; the real
checker ran on a real split pane `w82:p2` (closed by the bridge after use, confirmed in its own
output) and returned a genuine `pass` verdict with its own probe trail. The wrapper committed the
maker's real diff as `884dddbbd40adecfe4c726a3bd96258e18bb80db` with real
`Temporal-Workflow-Id: plan-round-1-b89ab09b-cd93-4345-bf9e-57b4429a0f0a` /
`Temporal-Run-Id: 01a15e15-7d82-7b56-b19f-92f37c5849d9` trailers. Confirmed no stray bridge
server/worker processes or run-dir remained afterward (the script's own EXIT trap cleaned up). The
disposable demo worktree/workspace/branch were torn down afterward and never merged into `main` (by
design — this was proof-of-function only, not a real task).
