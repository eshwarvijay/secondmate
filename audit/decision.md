# decision.md — decision audit trail

Append one entry per task. Format: date, task id, what the maker decided, checker findings, gates auto-approved or escalated and why.

---
## 2026-09-01 — plan-committee: --version flag

- **Maker (pi Qwen3-Coder):** implemented --version using cwd-relative `.claude-plugin/plugin.json` (wrong) and `jq -r` without null guard (wrong). Required 3 correction rounds.
- **Checker findings resolved:** (1) cwd-relative path → `SCRIPT_DIR/../` fix; (2) `jq` null → `jq // empty`; (3) selfcheck cwd inheritance; (4) SIGTERM trap with interpolated paths → function trap
- **Gates:** verify-gate refused on untracked `.secondmate/` state dir → added `.gitignore`, re-ran, PASS
- **Escalation:** none — all decisions made by supervisor
- **Herdr pane marker lesson:** use unique per-round markers (`___SM_R2_DONE_`) to avoid matching stale buffer output from previous rounds

---
## 2026-09-01 — skill: thinking medium + loop-back contract

- **Decisions:** (1) pi maker `--thinking off` → `medium`; (2) checker fail → supervisor synthesizes plan → task-scoped maker, never inline fix; (3) refused/error → escalate not loop; (4) all maker agent names task-scoped (`sm-<task-id>`); (5) visible recipe: spawn not delegate, guard on mk_pane before prompt; (6) checker recipe: --diff-base required; (7) unique round markers per checker run
- **Bugs caught by checker:** stale global agent name, README not updated, eval grader stale, hardcoded sm-maker in visible recipe, missing --diff-base in checker recipe, delegate returns no pane_id, spawn guard missing
- **Escalations:** none
