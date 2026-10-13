## 2026-10-13 — fix-banner-thinking-wording: sync stale pi-maker routing wording in session-activate.sh banner to SKILL.md

**Task**: bin/session-activate.sh's SessionStart banner (and its --selfcheck assertions) said the simple-task
maker routes as "pi+Qwen --thinking medium (simple)". skills/secondmate/SKILL.md — the declared single
source of truth — routes every pi-maker launch site to `--provider amazon-bedrock --model global.zai.glm-5.3
--thinking max`. The banner had drifted stale.

**Plan committee**: full 6-model plan-committee.sh run (deepseek-r1, qwen3-80b, qwen3-coder, kimi-k3,
mistral-large3, glm5). `/adhd` was deliberately skipped per the user's own global CLAUDE.md gate — this was
a closed, mechanical fix with an already-known root cause (exact stale line and exact correct wording both
located by grep before planning started), which is the documented adhd-skip condition. Probes resolved from
repo evidence, no human escalation needed: (1) banner wording format — kept the banner's existing terse
shorthand style ("pi+GLM-5.3 --thinking max (simple)"), not literal CLI flags, mirroring README.md's own
established shorthand; (2) selfcheck coupling — unidirectional (assert the banner's own emitted text), same
pattern every existing assertion in the script already uses, no cross-file grep against SKILL.md introduced;
(3) other stale-wording sites — grepped README.md and docs/ARCHITECTURE.md, both already correct (GLM-5.3/
--thinking max), confirming scope was exactly the one file; (4) declined to build a version-drift-tolerant
matcher (deepseek-r1's suggestion) as over-engineering for a literal-text sync fix.

**Maker**: pi maker (`global.zai.glm-5.3`, `--thinking max`) on herdr, agent name `sm-pi-banner-wording`
(shortened from the `sm-pi-<task-id>` convention — the full task-id pushed the herdr agent name past its
32-character limit). Routed to pi per step 0d ("Simple": well-specified, pure text/selfcheck edit, no
external deps, no judgment calls).

**Rounds**: 2.
- Round 1: banner line changed, 3 selfcheck assertions added (1 assert-present, 2 assert-absent) following
  the script's existing idiom. Maker mutation-tested its own new assertions before replying DONE.
  Checker (cross-model, visible herdr pane) verdict: **fail** — found a real bug: the assert-present check
  used `grep -q` with an unescaped `.` in "5.3", a regex wildcard, so a malformed banner like "pi+GLM-5X3"
  would still pass selfcheck.
- Round 2: supervisor synthesized a fix plan (never fixed inline) and routed it back to the same
  task-scoped maker. One-line fix: `grep -q` → `grep -qF` on that single assertion. Maker re-ran the
  mutation test to prove the gap was closed, re-verified the round-1 regression tests still held. Checker
  verdict: **pass**, zero findings.

**Verify-gate**: PASS (clean worktree, non-empty diff vs main, checked-sha matched HEAD, selfcheck test
green).

**Merge**: human hold `d149f7bb` approved by Eshwar (human) via Hermes dispatcher. Merged
`sm/fix-banner-thinking-wording` → `main` as `1d3a72748dcd72f7d899506b8cdd91c203fc8bc2`, pushed to origin.
Teardown clean (worktree, branch, herdr pane/agent, claim-ledger all released) — confirmed via
`teardown-check.sh`.

**Doc-sync note**: merge-sequencer's generic pre-push reminder (README/ARCHITECTURE/plugin.json) was
checked and found not applicable — both docs already carried the correct GLM-5.3/--thinking max wording
(verified by grep during planning, before any edit), and no plugin version bump is warranted for a
text-only drift fix.
