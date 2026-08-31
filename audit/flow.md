# flow.md — orchestration audit trail

Append one entry per task. Format: date, task id, maker path chosen, planner models (if committee ran), round count, outcome.

---
## 2026-09-01 — plan-committee: --version flag

- **Maker path:** pi Qwen3-Coder via `herdr agent start --kind pi` in worktree root pane `w1A:p1`
- **Worktree:** `herdr worktree create` → `sm/plan-committee-version` workspace `w1A`
- **Planner committee:** skipped (small well-specified task)
- **Rounds:** 5 checker rounds (pi bugs caught by gpt-terra: cwd-relative path, null acceptance, selfcheck cwd, SIGTERM trap quoting)
- **Outcome:** merged to main at `275c523`
