## 2026-10-04 — STE-style sentence pass on maker boilerplate + checker prompts (cross-model clarity)

## Flow

**Trigger / rigor:** `ship` / `full` (checker + verify-gate + human hold) — task explicitly triaged as
risky/outward-facing despite being "just a style pass," since the touched text is injected into every
future maker and checker invocation across the plugin.

**Plan Committee:** ran unconditionally per SOP.
- 0a (adhd): 5 cognitive frames (regulator, competitor-breaking-it, remove-load-bearing-assumption,
  3am-on-call, biology) run as 5 parallel Claude sub-agent calls; synthesized directly by the supervisor
  (no further deepen sub-agents spawned, to control cost) into `.secondmate/planning/adhd.md`. Winning
  convergent ideas: structural rule-table/negation-polarity diffing as the verification method, byte-exact
  quarantine + call-site census for the embedded shell substitutions, single-context atomicity for the
  maker (one session, all three files, not fragmented per-file).
- 0b (multi-model planners): `plan-committee.sh` run with a dedicated `--out-dir` (the default
  `.secondmate/planning/` dir had stale unmarked artifacts from an unrelated prior run, so a task-scoped
  out-dir was used instead — same pattern several other concurrently-running sibling tasks were already
  using). 5 of 6 planners completed (deepseek-r1, glm5, mistral-large3, kimi-k3, qwen3-coder); qwen3-80b
  (architecture-angle planner) timed out even after plan-committee.sh's own internal retry and produced an
  empty file. Judged acceptable to proceed without it — this is a pure prose-style task with no
  architecture decision to make, so the architecture-angle planner was the least load-bearing of the six.
- 0c (synthesize): kimi-k3's holistic-risk pass was the standout — it built a full integration-surface map
  and found several non-obvious load-bearing invariants the task brief didn't spell out: the section
  heading "Maker prompt closing boilerplate" is itself an API every call site points to by name; the
  8th call site is an *indirect* reference ("...same fix plan and checklist") invisible to a literal
  pointer-phrase grep; the feature-list.json schema fields/enum are a persisted data contract in live
  worktrees, not just prose; the CALIBRATION ❌ example in checker-prompt.md is deliberately bad and must
  not be clarified; baseline byte counts on the boilerplate block (quotes/backticks/dollar-paren) give a
  mechanical post-edit equality check. All planner probes were resolved directly from repository evidence
  (file reads, git history, existing precedent) — none required human escalation.
- 0d (route): Claude maker, single session, per the task's own explicit routing instruction ("complex" —
  requires judgment to preserve exact semantics while rewriting prose across two files).

**Spawn:** `herdr worktree create` (branch `sm/ste-style-cross-model-prompts`, workspace `w5G`), marked via
`mark-maker.sh`, skills synced via `sync-worktree-skills.sh`, `caffeinate-guard.sh start`.

**Maker:** one round. Prompt built via a quoted-heredoc file (to keep the goal's own descriptive mentions
of `$(...)` syntax, and the boilerplate's fixed prose, literal) with the boilerplate's 3 trailing
substitution lines live-evaluated against the fresh worktree (round-state.md/feature-list.json absent on
round 1, so those two lines resolved empty; lesson-lookup.py ran for real and injected 4 relevant prior
lessons, including "stay in literal scope" and "maker must commit before DONE" — both directly on-point
for this task). Maker committed `927c5cc`, touching exactly the 3 intended files (48 insertions / 47
deletions), nothing else. Maker's own round-state.md independently reported the same verification steps
the supervisor re-ran (byte-count recount, call-site byte-identity, shell-parse test via a real
double-quoted assignment rather than a heredoc, `launch-checker.sh --selfcheck`).

**Check:** one round, visible pane (HERDR_ENV=1 strict-pane rule honored), `launch-checker.sh` with an
addendum binding the Plan Committee's own findings as the checker's HAMMER: semantic side-by-side diff
against `HEAD~1` with explicit negation/modal-polarity hunting, byte-identity check on the 3 substitution
lines and all 8 call sites, verbatim-CALIBRATION-example check, and a full machine-token inventory.
Checker (gpt-5.6-terra via the pi harness) returned `{"verdict":"pass","findings":[],...}`; `verdict.py`
confirmed exit 0.

**Gate:** `verify-gate.sh` PASS against `main` with `--checked-sha 927c5cc`.

**Hold:** opened by the sub-supervisor itself (id `df0e5945`); answered `approve` by a genuine human (the
dispatching top-level supervisor relayed this, but the sub-supervisor independently re-verified the raw
`decisions.jsonl` ledger entry itself — both the `hold` event's sha and the subsequent `answer` event were
confirmed present before treating it as real approval, per the standing rule that no agent message is
itself consent).

**Integrate:** `merge-sequencer.sh` merged `sm/ste-style-cross-model-prompts` → `main` as `f5f50a5e`,
pushed to origin.

**Teardown:** worktree + herdr workspace removed, branch deleted, claim released (teardown-check.sh
initially reported the claim-ledger entry still open — the sub-supervisor had claimed but not yet
released; released explicitly, re-ran teardown-check.sh to confirm clean).

**Doc-sync check (CLAUDE.md pre-push rule):** `docs/ARCHITECTURE.md`'s stage-3/stage-4 descriptions only
semantically restate the boilerplate/checker-envelope contract (not verbatim prose quotes, aside from the
`$([ -f <path> ] && cat <path>)` shell pattern and the JSON schema, both of which are unchanged) — no
doc-sync edit was needed. No `plugin.json` version bump, following the existing precedent that purely
editorial/prose-only SKILL.md changes don't bump version (reserved for cache-drift or functional changes).

**Outcome:** 1 maker round, 1 checker round, pass on first attempt, no fix loop needed.
