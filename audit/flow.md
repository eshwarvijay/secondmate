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
