# flow.md — orchestration audit trail

Append one entry per task. Format: date, task id, maker path chosen, planner models (if committee ran), round count, outcome.

---
## 2026-09-01 — plan-committee: --version flag

- **Maker path:** pi Qwen3-Coder via `herdr agent start --kind pi` in worktree root pane `w1A:p1`
- **Worktree:** `herdr worktree create` → `sm/plan-committee-version` workspace `w1A`
- **Planner committee:** skipped (small well-specified task)
- **Rounds:** 5 checker rounds (pi bugs caught by gpt-terra: cwd-relative path, null acceptance, selfcheck cwd, SIGTERM trap quoting)
- **Outcome:** merged to main at `275c523`

---
## 2026-09-01 — skill: thinking medium + loop-back contract

- **Change type:** skill-only (no bin/ changes) — 7 checker rounds via herdr pane
- **Checker:** gpt-terra, qa/coverage + research/assumption-audit lenses
- **Outcome:** clean pass at round 7. Pushed `7c27799`

---
## 2026-09-01 — plan-committee: checker-lens-quality planner prompts

- **Change type:** bin/plan-committee.sh + skills SKILL.md — 4 checker rounds via herdr pane
- **Checker:** gpt-terra, qa/coverage + qa/test-reality + research/assumption-audit lenses
- **Rounds:** 4 (generic selfcheck markers → dimension-specific markers → table-header substring → pass)
- **Outcome:** merged to main at `c63ed32`

---
## 2026-09-03 — scope-guard-hook: PreToolUse hook confining Claude maker sessions to their own worktree

- **Trigger:** real incident — a maker session touched credentials/unrelated files outside its intended scope in a different repo; team flagged unusual activity
- **Maker path:** Claude, `herdr agent start --pane <root_pane_id>` in dedicated worktree workspace `w16` (visible orchestration, no split off supervisor)
- **Worktree:** `herdr worktree create` → `sm/scope-guard-hook`
- **Planner committee:** skipped (design already scoped by supervisor across the conversation)
- **Rounds:** 6 checker rounds (pi/gpt-terra, redteam + qa lenses), each closing real CONFIRMED bypasses: (1) marker-deletion via `rm`, Bash var-expansion escape, `sh -c` credential wrap, crash-not-deny on malformed input; (2) broken `SM_WORKTREE_ROOT` env-var persistence (hook subprocesses don't share env across invocations), `python3 -c`/base64-pipe bypasses; (3) symlink TOCTOU (documented, not fixed), swallowed marker-install failure, no primary-checkout guard, `printf|sh` pipe bypass generalized; (4) `eval` wrapper bypass unified into the same nested-command recursion; (5) discovered scope-guard.py ONLY guards Claude Code sessions — pi makers get zero confinement (deliberately deferred, documented loudly rather than built); (6) docs-only round naming redirection/xargs/os.system-in-interpreter as permanent accepted limitations after supervisor called a stop to further Bash-heuristic patching (Turing-complete-adjacent — no finite patch set closes it)
- **Outcome:** verify-gate PASS at `781a620` (checked-sha match) → human hold `6beac00d` answered `merge` → merged to main (`--no-ff`) → worktree/branch/pane teardown complete
- **Lesson:** herdr-pane.sh's `spawn`/`split` originally always split off the CALLER's current pane, not the dedicated worktree workspace `herdr worktree create` already provisions — this caused real keyboard-focus/input bleed between supervisor and maker panes mid-task. Fixed in a companion task (`pane-routing-fix`, same day) to add `--pane <ID>` targeting.

---
## 2026-09-03 — pane-routing-fix: herdr-pane.sh --pane targeting, maker/checker stay off the supervisor's pane

- **Trigger:** discovered mid-task while running scope-guard-hook — maker pane landed as a split inside the supervisor's own workspace instead of the dedicated workspace `herdr worktree create` provisions, causing real keyboard-focus/input bleed and repeated `/model`-menu interruptions
- **Maker path:** pi (Qwen3-Coder-Next, `--thinking high`), `herdr agent start --pane <root_pane_id>` in dedicated worktree workspace `w17`, run in parallel alongside the scope-guard-hook task (non-blocking `herdr agent prompt` + separate `herdr agent wait` per task — no `--wait` coupling)
- **Worktree:** `herdr worktree create` → `sm/pane-routing-fix`
- **Rounds:** 8 total. 1-7 against isolated `--diff-base 6b06d13`: stray real panes created by `--selfcheck` itself (mock-herdr fix), `split down` backward-compat regression, zero real `--pane` test coverage, loose test assertions (accepted `--pane`+`--current` together), missing `delegate` coverage, `HERDR_ENV` not exported to mocked sub-invocations, empty-string `--pane ""` silently falling back to `--current`. Round 8 was a dedicated merge-reconciliation pass after scope-guard-hook merged first (both branches touched `bin/herdr-pane.sh`) — caught 3 regressions the merge itself introduced: `mark_maker()` fail-open shortcut reintroducing the swallowed-install-failure bug, real marker files leaking into `~/.secondmate-markers/` on every selfcheck run, stale `ARCHITECTURE.md` claim about spawn's default routing.
- **Outcome:** verify-gate PASS at `3942930` → human hold `942f7cdb` answered `merge` → merged to main (`--no-ff`, clean, no conflicts since reconciliation was already baked into the branch) → repo-wide selfcheck chain re-run clean (`ALL_OK`) → worktree/branch/pane teardown complete → 20 stale marker files (pre-dating the round-8 fix) manually cleaned from `~/.secondmate-markers/`, one legitimate marker kept
- **Lesson:** independently re-running selfchecks/checkers yourself (not trusting a maker's "all pass" summary) caught two real bugs this task alone: the merge-interaction bug (spawn's mock test collided with `mark_maker`'s primary-checkout guard) and the merge-reconciliation regressions. Both were invisible to either branch's isolated review and only surfaced by testing the ACTUAL merged result.
