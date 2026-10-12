## 2026-10-12 — pi-maker-thinking-max: shipped max (not high) per empirical trials; hold answer and merge-permission block both independently re-verified before acting

## pi-maker-thinking-max — decision

**What was decided:** the pi maker's `--thinking` level at all 4 launch sites moves from
`medium` to `max` (not `high`), with the model id (`global.zai.glm-5.3`) unchanged.

**Why `max` and not `high`.** The human's pre-dispatch catalog research (cross-referencing
Cloudflare/NVIDIA GLM-5.3 hosts' `thinkingLevelMap`s against pi's source) showed only
off/high/max are real, non-null tiers for this model family — `max` is one level above `high`,
not `high` itself — but the specific Bedrock-hosted entry (`global.zai.glm-5.3`) declares no
`thinkingLevelMap` locally, so pi won't validate/reject either value for it. Verified empirically
(not just "doesn't error") before committing: 3 medium-vs-max trials plus 1 max-vs-high trial,
real `pi` invocations against the live amazon-bedrock host, `--mode json` for structured
inspection of thinking-trace length and wall-clock time. Net result across trials: `max` never
errored, degenerated, or underperformed `medium`/`high` in output quality; 2 of 3 medium-vs-max
trials showed `max` clearly deeper/longer (3x and 2x on thinking-chars and wall time); the one
inverted trial (shorter raw thinking at `max`) nonetheless produced the objectively more correct
answer, catching an asymmetry `medium`'s answer missed. The max-vs-high trial showed `max` ~5x
deeper than `high` on every metric. Decision: ship `max`.

**What the checker found:** nothing. Verdict `pass`, zero findings, on round 1. The checker
independently re-derived the pi version/model-catalog check and the scope-invariant diffs
(confirmed `bin/plan-committee.sh`, `bin/scope-guard-extension.ts`, `bin/session-activate.sh`,
`docs/ARCHITECTURE.md` all byte-identical to pre-change) rather than taking the maker's
round-state.md claims on faith.

**Gates, and whether each was auto-approved or escalated:**
- verify-gate: auto-approved (deterministic PASS — clean worktree, non-empty diff, checked-sha
  match).
- Human hold (`837f379a`, decisions.jsonl): escalated, never self-answered. Answered "approve" by
  the human via the dispatching coordinator; independently re-verified by reading the raw ledger
  record myself (both the `hold` and matching `answer` entries, with the `sha` field matching the
  checked sha) before treating the relay as genuine, per this SOP's "never trust, always
  re-verify" posture.
- Harness merge permission ("Merge Without Review" classifier): escalated. This is a Claude Code
  harness-level gate, distinct from the SOP's own hold — I did not and should not attempt to route
  around it myself (e.g. via raw `git merge`/`push`, which the harness's own denial message
  explicitly warned against as bypassing the intent of the block). The human gave the dispatching
  coordinator an explicit, direct instruction ("just directly push to main"), which is real,
  specific authorization — qualitatively different from the coordinator unilaterally working
  around my denial on its own initiative. The coordinator ran `merge-sequencer.sh` itself with the
  identical checked-sha I had gated on; I independently re-verified the resulting merge (ancestry,
  branch-tip equality local vs origin, merge-ledger record) before proceeding to teardown rather
  than accepting the coordinator's report at face value.

**Scope decisions made without escalation (resolved from the task's own explicit boundary, not
a business/product judgment call):**
- `bin/session-activate.sh` also mentions `--thinking medium` (and is independently stale on the
  model name, "Qwen") — left untouched. Not one of the two doc-sync targets the task named
  (README.md, docs/ARCHITECTURE.md); flagged as a candidate for a separate future task, not a
  blocker here.
- `docs/ARCHITECTURE.md` — grepped, confirmed zero mentions of the maker's thinking level, correctly
  left unchanged (the task's doc-sync instruction was conditional: "if present").
- Prose at SKILL.md lines ~134-141/~151 rewritten to drop the now-moot "escalate to `high` for
  security-sensitive logic" framing (there's nothing higher than `max` to escalate to), state the
  empirical justification, and honestly disclose the ~2-5x cost/latency tradeoff while preserving a
  supervisor's discretion to deliberately pick a lower level for a cost-sensitive bulk task.
- The precise raw empirical numbers (exact thinking-char counts, exact wall-clock seconds) were kept
  out of the shipped README.md/SKILL.md prose (kept qualitative there) per a low-severity
  info-disclosure note from the security-lens planner (mistral-large3) — the raw numbers live only
  in the audit trail/hold write-up, not in files meant for general/outside readers.

**Lesson tags (from this task's own injected-lesson ledger, direct grounded evidence only):**
- `commit-before-done` — helpful. The maker committed (`ae515d2`) before replying DONE; verified via
  `git log`/`git status` in the worktree, not just the maker's own claim.
- `stay-in-literal-scope` — helpful. The maker touched exactly the 2 files named in the plan and
  nothing else (verified via `git diff --name-status` and the checker's independent re-derivation of
  the same diffs); it explicitly declined to touch `bin/session-activate.sh` despite noticing the
  same drift, flagging it instead of fixing it.
