## 2026-09-30 — loop-harness-upgrades: feature-list.json ledger (P1) + premature-victory guard (P2) + startup checklist (P3) in maker-prompt boilerplate

## Flow — loop-harness-upgrades

**Trigger:** solo dispatch (fresh sub-agent-supervisor), triaged `ship`/`full` rigor (checker + verify-gate +
human hold) per the task framing — a change to SKILL.md's canonical maker-prompt boilerplate affects every
future task, so it is risky/outward-facing despite being docs+prose only.

**Plan Committee:** adhd (5 divergent frames: regulator, competitor/adversary, logistics, 3am on-call,
biology) + 6-model plan-committee.sh (deepseek-r1, glm5, kimi-k3, mistral-large3, qwen3-coder completed;
qwen3-80b timed out twice on both attempts and was excluded). All completed sources independently converged
on the same shape: no new `bin/` script, `feature-list.json` written inline by the maker using
round-state.md's existing atomic temp-file+mv idiom, and `loop-guard.sh` left unmodified (the existing
prompt command-substitution injection block is what "feeds" the restart path). kimi-k3's repo-verified
integration-risk pass also surfaced a real pre-existing doc gap (`SM_ROUND_STATE` missing from README's
config-vars table) that got folded into the fix. Consolidated plan written to
`.secondmate/planning/loop-harness-upgrades/CONSOLIDATED.md`.

**Maker routing:** Claude, per step 0d "complex" routing (judgment-heavy prose editing requiring coherent
cross-referencing of three interdependent SKILL.md sections). Ran directly on the herdr worktree's root_pane
(worktree `sm-loop-harness-upgrades`, branch `sm/loop-harness-upgrades`).

**Rounds:** 2.
- Round 1 (commit `1185690`): added all three additions (A: optional feature-list.json ledger, B:
  premature-victory guard, C: session-startup checklist) to the boilerplate block, plus README.md/
  docs/ARCHITECTURE.md doc-sync. Checker (pi/GPT-5.6-terra via launch-checker.sh, lenses `qa/test-reality` +
  `qa/coverage`) returned **fail**: (1) ARCHITECTURE.md's new sentence implied feature-list.json is
  unconditionally injected every prompt, contradicting its own optionality contract; (2) the maker's cited
  DONE-evidence (`claude plugin validate .`) only validates the marketplace manifest, never exercising the
  actual changed behavior (the conditional cat substitutions).
- Round 2 (commit `0b680cf`): maker reworded the ambiguous sentence and — dogfooding the very guard this
  task adds — wrote a throwaway verification script, ran it against real temp dirs proving zero-bytes-when-
  absent / real-content-when-present, cited the actual output in round-state.md, then deleted the scratch
  files (clean tree). Checker returned **pass**, 0 findings, both lenses covered
  (`lens_coverage: {qa/test-reality: true, qa/coverage: true}`).

**Gate:** `verify-gate.sh` PASS at checked sha `0b680cf7dac36839d91d7f810e9fc349be409356` (clean, non-empty
vs main, checker-current).

**Hold:** opened `caca1d1d` (never self-answered). A coordinator later reported a human answer; independently
re-verified by reading the raw `decisions.jsonl` ledger directly (not trusting the coordinator's claim) —
confirmed the `hold` record's sha matched the checked sha exactly, and a genuine `answer` event with
`a: "yes"` was present, before proceeding.

**Integrate:** `merge-sequencer.sh` merged `sm/loop-harness-upgrades` → `main` as
`8840818f6c429b9df5ea395e5947f19677441592`, pushed to origin.

**Teardown:** checker pane closed, herdr worktree + workspace removed, branch `sm/loop-harness-upgrades`
deleted, claim released. `teardown-check.sh` reported fully clean.

**Outcome:** merged, clean teardown, no lingering worktree/branch/claim.
