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
