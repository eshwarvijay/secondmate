## 2026-10-02 — sub-supervisor-todo-list: require dispatched sub-supervisors to self-track SOP steps via TodoWrite

**Maker path:** Claude maker (routed per step 0d as "complex" — judgment call on the single best insertion
point in an already-dense SKILL.md, with an explicit risk of conflating the new instruction with
`progress-ledger.py`'s separate cross-task checkpoint mechanism).

**Plan Committee:** ran unconditionally — 0a adhd ideation (3 frames: regulator, 3am-on-call,
remove-the-load-bearing-assumption; scaled down from the default 5 frames since this was a narrow
documentation-placement decision, not an architecture/strategy call) + 0b `plan-committee.sh` 6-model
run (deepseek-r1, qwen3-80b, qwen3-coder, kimi-k3, mistral-large3, glm5) in a task-scoped `--out-dir`
(`.secondmate/planning-sub-supervisor-todo-list`) to avoid colliding with sibling sub-supervisors
(`sm-loop-harness-upgrades`, `sm-maker-prompt-guardrails`) sharing the default `.secondmate/planning`
dir in this session. 0c synthesis was delegated to a `fork` sub-agent, which — since forks inherit the
full dispatching context — went beyond its synthesis brief and executed Spawn through Gate itself
(worktree, Claude maker, cross-model checker, verify-gate). Every claim it reported was independently
re-verified by the supervisor (claim-ledger status, raw `decisions.jsonl`, `git log`/`git show` on the
worktree, the raw checker verdict file, and a fresh independent re-run of `verify-gate.sh`) before the
supervisor proceeded — nothing was taken on the fork's word alone.

**Round count:** 1 round. Checker verdict: `pass`, zero findings, on the first attempt — no fix-loop
needed.

**Outcome:** merged to `main` as `57bdfc0` (squash of `sm/sub-supervisor-todo-list` at checked-sha
`542436f`). Full teardown confirmed clean via `teardown-check.sh` (worktree, branch, herdr workspace,
claim-ledger all clean) after `herdr worktree remove --workspace w58`, `git branch -d
sm/sub-supervisor-todo-list`, and `claim-ledger.py release`.
