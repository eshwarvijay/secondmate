## 2026-10-12 — pi-maker-thinking-max: flip pi maker --thinking medium -> max, empirically verified, 2 human-driven interventions on hold+merge

## pi-maker-thinking-max — flow

**Task:** flip the pi maker's `--thinking` level from `medium` to the true maximum GLM-5.3
supports on `amazon-bedrock` (`global.zai.glm-5.3`), at the 4 existing pi-maker launch sites in
`skills/secondmate/SKILL.md` (herdr first-round, headless first-round, herdr fix-round, headless
fix-round), plus doc-sync.

**Plan Committee.** `/adhd`'s own pre-flight gate aborted divergence before Phase 1 — this had
already become a canonical, single-answer decision once the empirical check (below) resolved it,
and the dispatch brief was closed/directive rather than open-ended (logged at
`.secondmate/planning/pi-maker-thinking-max-adhd/adhd.md`). Ran the full 6-model `plan-committee.sh`
(deepseek-r1, qwen3-80b, qwen3-coder, kimi-k3, mistral-large3, glm5) — all 6 exited 0. Synthesized
into `.secondmate/planning/pi-maker-thinking-max/CONSOLIDATED.md`, resolving every probe the six
planners raised (notably kimi-k3's catch that README.md has *two* `--thinking medium` mentions, not
one, and that `bin/session-activate.sh` also mentions it but is out of this task's named doc-sync
scope).

**Empirical verification (the task's central ask).** Before routing any maker, ran real
`pi --provider amazon-bedrock --model global.zai.glm-5.3 --mode json --no-tools -p "<prompt>"`
invocations at `--thinking medium/high/max` across 3 different reasoning prompts (sheep riddle,
restaurant-bill split, snail-on-a-wall). Trial 1: max was ~3x deeper/longer than medium, ~5x deeper
than high. Trial 2: inverted on raw thinking-length (medium produced more raw chars) but max's final
answer was objectively more correct. Trial 3: max modestly longer, both correct. In no trial did
`max` error, degenerate, or do worse than `medium`/`high`. Also inspected the pi package's bundled
model-catalog JSON directly (`node -e "require(...)"` against
`@earendil-works/pi-ai/dist/providers/data/{amazon-bedrock,cloudflare-workers-ai,nvidia}.json`):
confirmed every GLM-5.3 host that declares a `thinkingLevelMap` (Cloudflare, NVIDIA) treats only
off/high/max as real non-null tiers for this model family, and that the Bedrock entry
(`global.zai.glm-5.3`) declares no `thinkingLevelMap` at all — consistent with the human's own
pre-dispatch research. Decision: ship `--thinking max`, not `high`.

**Maker.** Routed to the pi maker via herdr (`sm-pi-pi-maker-thinking-max`, worktree
`sm/pi-maker-thinking-max`) — a well-specified, pure-text edit with no ambiguous judgment calls once
the empirical question was resolved. One clean round. Commit `ae515d2`: changed only
`skills/secondmate/SKILL.md` (4 launch sites + adjacent prose at ~134-141/~151) and `README.md`
(mermaid node line 66, prose line 78). `docs/ARCHITECTURE.md`, `bin/plan-committee.sh`,
`bin/scope-guard-extension.ts`, `bin/session-activate.sh`, and the model id `global.zai.glm-5.3` all
verified byte-unchanged. Maker self-verified via grep before replying DONE and wrote a thorough
round-state.md; no feature-list.json (single-round doc task, not needed).

**Checker.** Cross-model (`global.openai.gpt-5.6-terra`), edit-locked, run visibly in a herdr pane
per the strict `HERDR_ENV=1` rule. Verdict: **pass**, zero findings, after independently re-deriving
the catalog check and the scope-invariant diffs itself.

**Gate.** `verify-gate.sh` → PASS (clean worktree, non-empty diff vs `main`, checked-sha matched
HEAD).

**Hold and merge — two interventions, both human-driven, neither a self-grant.**
1. Opened durable hold `837f379a` with the full honest write-up (including the one inverted
   empirical trial and the ~2-5x cost/latency tradeoff) and stopped — I cannot answer my own hold.
   The dispatching coordinator later resumed me reporting the hold had been answered "approve"; I
   independently re-verified by reading the raw `decisions.jsonl` ledger myself (not trusting the
   relay) before treating it as genuine.
2. `bin/merge-sequencer.sh` was then blocked outright by the Claude Code harness's own auto-mode
   classifier ("Merge Without Review") — a permission gate separate from and in addition to the
   SOP's hold. Per the harness's own instructions I did not attempt to route around it (e.g. running
   the underlying `git merge`/`push` myself), and stopped to report the blocker, leaving everything
   (claim, worktree, branch, herdr workspace, caffeinate-guard) untouched. The coordinator then
   reported the human gave an explicit, direct instruction ("just directly push to main") and ran
   `bin/merge-sequencer.sh` itself with the same checked-sha I had gated on — a genuine human
   authorization, not permission-laundering. I independently re-verified the result myself before
   continuing: `git log --oneline` on `main`/`origin/main` both show `825a090 Merge
   sm/pi-maker-thinking-max` with `ae515d2` as a confirmed ancestor (`git merge-base
   --is-ancestor`), local and origin in sync at `27468c8`, and the merge-ledger's own record
   (`reason_code: PUSH_RACE_RECOVERED`, `merged_sha: 27468c8...`) matches. Only after that
   independent verification did I proceed to teardown.

**Teardown.** Checker pane closed, `herdr worktree remove --workspace w6N`, branch
`sm/pi-maker-thinking-max` deleted, claim released, `teardown-check.sh` reports clean on all four
axes (worktree/branch/herdr/claim).

**Round count:** 1 maker round, 1 checker round, 0 fix rounds (checker passed clean on round 1).
