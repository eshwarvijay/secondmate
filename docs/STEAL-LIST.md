# Steal list — features worth adopting from starred repos

Research pass across the user's starred GitHub repos, focused on concrete features to adopt into
secondmate. Every entry is mapped to a specific, already-documented gap in this repo's own
architecture docs and audit trail (`README.md`, `docs/ARCHITECTURE.md`, `skills/secondmate/SKILL.md`,
`audit/decision.md`) — not a generic feature comparison.

## Tier 1 — direct hits on gaps this repo already named

### 1. MisakaNet → turn "Known failure patterns" into a retrievable lesson store
**What they do:** git-backed library of failure lessons as plain Markdown, BM25 search over stdlib
Python, evidence levels E0→E4 (intake → CI → merged PR → maintainer → production reuse). Their own
benchmark: injecting the matching lesson roughly doubles a weak model's hit rate (21%→43%).

**Why it's #1:** `SKILL.md` pastes the same 4-bullet "Known failure patterns" block verbatim into
~8 different maker-prompt sites. It's manually curated, grows monotonically, and is injected
regardless of task relevance. Every bullet in it was earned the hard way and is already recorded in
`audit/decision.md` (not-committed, fake-test, scope-creep, one-liner loops).

**Steal concretely:**
- `bin/lessons/<category>/<slug>.md` with frontmatter (`tags`, `evidence: E0-E4`, `earned-in: <task-id>`)
- `bin/lesson-lookup.sh --task "<desc>"` → BM25 over lessons → inject only the top 3 relevant into
  maker prompts instead of the full static block
- Close the loop: a checker `fail` verdict with a new finding category becomes a lesson intake
- Zero new dependencies — BM25 over stdlib only

### 2. oh-my-subagents → kill the "no liveness/reaping" limitation
**What they do:** durable Waves, terminal Checkpoints, controller-owned state — a browser closure or
provider interruption never fabricates completion; the parent resumes from committed records instead
of polling.

**Why:** `SKILL.md`'s fan-out section ends with a named, deliberately-deferred limitation: a dead
sub-supervisor leaks its claim and worktree, and a human must manually reap it.

**Steal concretely:**
- `dispatch-report.py`'s `SM_DONE_MERGED`/`SM_STUCK`/`SM_REFUSED` tags are already the seed of a
  Checkpoint contract — formalize it with a heartbeat file (`<task-id>.heartbeat`, touched per round)
  next to the claim
- `bin/claim-ledger.py reap --stale-after 30m` → lists claims with dead heartbeats (advisory only, no
  auto-steal — matches this repo's existing "human removes it manually" philosophy)

### 3. foremerge → intent declarations on top of claim-ledger
**What they do:** agents announce intended scopes (`symbol:X`, op `replace|extend`) into a shared
store; a deterministic (no-LLM) conflict detector raises an advisory when two agents' plans collide
semantically — the case plain git can't see (different files, colliding intent).

**Why:** `merge-sequencer.sh` is excellent at SHA-level freshness; `claim-ledger.py` claims task-ids —
but nothing today catches two fan-out tasks that semantically conflict without touching the same
lines.

**Steal concretely:** extend claims with `--intents "bin/plan-committee.sh:modify, skills/secondmate:extend"`
(paths the plan-committee synthesis step already identifies); warn on overlap at claim time, advisory
only, never blocking — matches this repo's own precedent exactly.

### 4. agent-workspace-linux → real OS sandboxing for scope-guard's permanent gap
**What they do:** OS-level confinement via bubblewrap.

**Why:** `README.md`'s own accepted-limitations block states scope-guard is text-heuristic only and
that closing it "for real needs OS-level sandboxing (chroot/seccomp/containers), explicitly out of
scope."

**Steal concretely (minimal version):** wrap maker launch in `sandbox-exec` on macOS (built-in, no
deps) confining writes to the worktree; `bwrap` on Linux. Keep `scope-guard.py` as defense-in-depth,
not the only wall.

### 5. plannotator → upgrade `hold.py` from y/n text to annotated review
**What they do:** local browser surface for inline annotation of plans/diffs, feedback sent back to
the agent with one click. Already supports pi, with a "Herdr Annotate" terminal mode.

**Why:** the human's only interaction today is `hold.py answer <id> --a "merge"` on a chat-rendered
diff.

**Steal concretely:** hook plannotator into the Hold step when `HERDR_ENV=1` — annotate the
consolidated plan before the maker spawns (a plan gate this repo doesn't currently have), and annotate
the diff at merge time.

### 6. whip → live model-catalog validation in `doctor.sh`
**What they do:** live discovery from every provider's model catalog.

**Why:** the `kimi-k3-planner-swap` task (`audit/flow.md`, 2026-09-23) hit exactly this failure —
pi's remote catalog had a wrong `maxTokens` for a Bedrock model, blocking the task mid-flight. Model
IDs are hardcoded literals in `bin/plan-committee.sh`.

**Steal concretely:** a `doctor.sh` check that queries the live Bedrock catalog and validates every
configured model ID + token limit pre-flight. Already an approved follow-up in this repo's own audit
trail.

## Tier 2 — valuable, more invasive

| Repo | Feature to steal | Integration point |
|---|---|---|
| ai-memory | Typed, claimed-exactly-once handoff records + git-backed markdown memory with access-weighted decay | `audit/flow.md`/`decision.md` are append-only prose that grows forever; steal structured `handoff.jsonl` per task + a decay/compaction policy |
| amplio | DB-first crash-resume anywhere in the loop + per-run reports/grades | `audit/metrics.jsonl` exists but is barely populated — a resumable run state machine + a post-run grade appended to it |
| gear | Evaluation-driven harness refinement: benchmark → eval → iteratively tune prompts/tools/effort | `evals/verdict-envelope` is one eval; steal the loop — which checker prompt/lens/thinking-level actually produces real-bug findings, feeding back into `checker-prompt.md` and lens routing |
| google/ax | Network egress allowlist per task + declarative task spec | scope-guard confines files; nothing confines network today — a maker can exfiltrate via `curl` freely |
| cc-connect | Answer holds from Telegram/Slack/phone | unattended runs stall at Hold; push notification + reply-as-answer makes overnight batches practical |
| AutoHarness | Cost governance per round | `log-round.sh --cost` exists but is never populated — a thin cost-ledger closes "what did this task cost" |

## Tier 3 — interesting, not worth stealing yet

- **AnyJev/kev/jeff** (calibrated verdict probabilities) — right idea (a confidence field on the
  verdict, threshold auto-decide for fast-tier tasks), but requires local-logit access this repo's
  Bedrock-hosted checker doesn't expose. Revisit if a local decision model is ever added.
- **squad** (persistent team definitions) — this repo's roles are already well-defined; team-as-files
  adds little over `SKILL.md` + env config.
- **JITMIND/SimpleMem** (bi-temporal/graph memory) — overkill; MisakaNet + ai-memory cover the same
  ground more simply.

## Suggested sequencing

1. Lessons store (MisakaNet) — highest leverage, zero deps, pure win
2. `doctor.sh` catalog check (whip) — already approved on this repo's own roadmap, small
3. Heartbeat + reap (oh-my-subagents) — closes an already-named limitation
4. Intent claims (foremerge) — extends claim-ledger, uses data plan-committee already produces
5. `sandbox-exec`/`bwrap` profile (agent-workspace) — biggest security upgrade, needs careful selfchecks
6. plannotator Hold integration — UX, when wanted
