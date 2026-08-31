# decision.md — decision audit trail

Append one entry per task. Format: date, task id, what the maker decided, checker findings, gates auto-approved or escalated and why.

---
## 2026-09-01 — plan-committee: --version flag

- **Maker (pi Qwen3-Coder):** implemented --version using cwd-relative `.claude-plugin/plugin.json` (wrong) and `jq -r` without null guard (wrong). Required 3 correction rounds.
- **Checker findings resolved:** (1) cwd-relative path → `SCRIPT_DIR/../` fix; (2) `jq` null → `jq // empty`; (3) selfcheck cwd inheritance; (4) SIGTERM trap with interpolated paths → function trap
- **Gates:** verify-gate refused on untracked `.secondmate/` state dir → added `.gitignore`, re-ran, PASS
- **Escalation:** none — all decisions made by supervisor
- **Herdr pane marker lesson:** use unique per-round markers (`___SM_R2_DONE_`) to avoid matching stale buffer output from previous rounds
