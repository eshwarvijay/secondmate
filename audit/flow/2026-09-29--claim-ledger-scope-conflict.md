## 2026-09-29 — claim-ledger.py: declared scope+operation claims + read-only conflicts check (stolen idea from foremerge)

**Origin:** researched `github.com/naw103/foremerge` (a Rust/SQLite/MCP semantic-conflict tool for parallel
coding agents) at the human's request; identified the one steal worth taking — declared scope+operation
conflict detection, not foremerge's own machinery — and the human said "ok plan committee and start".

**Plan committee:** adhd fork (in-process, cognitive frames) + 6-model `plan-committee.sh`
(deepseek-r1, glm5, mistral-large3, qwen3-80b, qwen3-coder, kimi-k3) against a fresh task-scoped
`--out-dir` (the default `.secondmate/planning` had stale unmarked output from prior tasks and refused to
overwrite). All planner probes were answered directly from reading the real `bin/claim-ledger.py` (704
lines) rather than escalated — no OPEN DECISIONs, no human questions needed before the maker started.
Key probes resolved: additive/destructive split (add/extend/modify vs replace/remove/rename/migrate, as
adhd converged), CLI shape (one combined `--scope KIND:KEY=OPERATION` flag, not two), no-lock read path
for `conflicts` (matches existing `status`/`list` precedent), mixed-version ledger safety (verified
`_recs()` already ignores unknown JSON keys, no compat shim needed), SKILL.md dispatcher-wiring explicitly
declared out of scope for this task.

**Maker:** Claude (complex route — concurrency/TOCTOU-sensitive shared infra, chose judgment over pi).
Worktree `sm/claim-ledger-scope-conflict`, root pane on workspace `w3Q`.

**Rounds:** 2.
- Round 1: checker (qa/test-reality + qa/coverage + qa/risk-flagging lenses) found one CONFIRMED real bug
  — `_SCOPE_RE` used `[^\s=]+` and rejected whitespace in the scope's KIND:KEY, contradicting the spec's
  "scope is free text like `--owner`, no new sanitization" decision. Verdict: fail.
- Fix routed back to the maker (not fixed inline) with the exact file:line and the minimal targeted
  change (`[^\s=]+` → `[^=]+`, keep required `:` and the `=` delimiter). Maker committed `a70dfc0`.
- Round 2: checker re-verified against the exact fix commit (worked around this repo's known
  checker-cwd gap itself, via `git show a70dfc0:...` rather than a live cwd) — pass, no findings, all
  round-1 CLEAN items re-confirmed.

**Gate:** `verify-gate.sh` — first invocation refused on a supervisor error (passed the short SHA `a70dfc0`
instead of the full 40-char SHA; verify-gate does an exact string compare, no prefix matching). Re-ran with
the full SHA `a70dfc060da1c8a521ed89dab7308d5951c37321` → PASS (clean, non-empty vs main, checker-current,
`selfcheck` green).

**Hold → merge → teardown:** genuine human "yes", SHA-bound to `a70dfc060da1c8a521ed89dab7308d5951c37321`.
Merged via `merge-sequencer.sh` as `2bee3677` (pushed to origin). Checker pane closed, worktree+workspace
removed, `sm/claim-ledger-scope-conflict` branch deleted.
