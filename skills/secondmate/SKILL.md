---
name: secondmate
description: >
  Maker/checker loop for shipping a verified code change: triage → isolated
  worktree → maker implements → cross-model edit-locked checker emits a
  {verdict} envelope → verify-gate → durable human hold → integrate. Use when
  the user wants a change made AND independently verified before it lands, asks
  to "run the maker/checker loop", "review with a cross-model checker", gate a
  merge, or run a long iterative edit→check loop safely. Also exposes a read-only
  reasoning one-shot for root-cause/triage/plan-review. Skip for trivial one-shot
  edits or read-only questions.
---

# secondmate — maker/checker loop hardening

**Setup:** run `/secondmate-doctor` once — it detects and installs the harness + companions (herdr, ponytail,
adhd) and reports what's missing; the human only approves each action. The `/loop-task` command ships
with this plugin. Cross-model checking
additionally needs a second model family + credentials, which only the human can supply.

Scripts live in `${CLAUDE_PLUGIN_ROOT}/bin/` (a `${CLAUDE_PLUGIN_ROOT}/bin/reason.sh` etc.).
If `$CLAUDE_PLUGIN_ROOT` is unset in your shell, resolve it once: it is this plugin's install dir
(under `~/.claude/plugins/marketplaces/secondmate` or your skills dir). All scripts carry `--selfcheck`/
`selfcheck` and are harness-neutral; the checker/reasoning harness + model are set by env
(see the Config section of the plugin README). You (the supervisor) invoke these — the user does not.

## Roles
- **Supervisor** (you) — triage, adjudicate, gate, integrate. Never write project code yourself.
- **Maker** — implements in an isolated worktree (e.g. a Claude `/loop-task`).
- **Checker** — a *different* model, edit-locked, that reviews the diff and emits a verdict. Its blind
  spots must not correlate with the maker's, so run a different model family than the maker. If no external
  harness is installed, the fallback is a different-model Claude sub-agent (same vendor, weaker, but maker is
  still not the checker) — see the Check step.

## Plan Committee (pre-triage, complex and ambiguous tasks only)

Before triaging, run the planning committee to gather independent perspectives from multiple models.
**Skip for trivial edits, known-root-cause bugs, or mechanical changes — earns its cost only on open-ended or high-stakes tasks.**

**0a — adhd subagent (Claude cognitive frames, you run this):**
Invoke `/adhd` as a Claude sub-agent; save its winning branch to `.secondmate/planning/adhd.md`.

**0b — multi-model planners (parallel, 6 models):**
```
${CLAUDE_PLUGIN_ROOT}/bin/plan-committee.sh --task "<task description>" [--timeout 300]
```
Spawns 6 headless pi planners in parallel (DeepSeek-R1 → failure modes; Qwen3-Next-80B → architecture;
Qwen3-Coder-Next → implementation; Kimi-K2-Thinking → holistic risk; Mistral-Large-3 → security;
GLM-5 → requirements/product). Outputs: `.secondmate/planning/<label>.md`.

**0c — synthesize (you, the supervisor):**
Read all `.secondmate/planning/` files in order:

1. **Collect probes.** Every planner ends with a `### Probes for Supervisor` section — 2-3 questions
   it raised but could not answer (planners are headless, no tools). Read the six `<label>.md` files
   (skip `audit.jsonl` and any stale outputs). List all probes before writing anything.

2. **Answer every probe.** For each probe, resolve it using your session context: read the relevant
   file, grep the codebase, check the package manifest. If a probe requires a file read, do it now.
   - **If a probe is answerable from the repository:** answer it and record the evidence.
   - **If a probe requires a business, legal, or product decision not in the repo:** record it as an
     OPEN DECISION, escalate to the human before proceeding, and do not invent an answer.
   A probe left unanswered without escalation is a supervisor failure — the maker must not receive it.

3. **Extract signal, discard noise.** Weak analysis, duplicate findings, and generic advice go.
   Keep only concrete, task-specific findings from each dimension.

4. **Write ONE consolidated plan.** Bind the probe answers into the plan so the maker gets a
   spec that is already resolved — no open questions, no "figure it out" gaps. OPEN DECISIONs that
   were escalated are excluded from the plan until the human answers them.

This is the spec the maker receives.

**0d — route the maker** (after step 2 Spawn has created `<wt>`):
- **Complex** (needs judgment mid-task, MCP tools, ambiguous sub-steps) → Claude maker:
  ```bash
  read mk mk_pane < <(herdr-pane.sh spawn --name sm-<task-id> --kind claude --dir right \
    --cwd <wt> -- --permission-mode acceptEdits)
  [ -n "$mk_pane" ] || { echo "spawn failed — abort" >&2; exit 1; }
  herdr agent prompt sm-<task-id> "/loop-task <goal>" --wait --timeout 600000
  ```
  Use `spawn` (not `delegate`) to capture `$mk_pane` for cleanup. Guard on `$mk_pane` before prompting —
  if spawn fails (Herdr unavailable, split error), abort rather than routing to a stale agent.
  Same `<task-id>` slug as the worktree branch. Plan can be higher-level; Claude resolves ambiguity itself.
- **Simple** (well-specified, pure code, no external deps) → pi maker via herdr (when `HERDR_ENV=1`):
  ```bash
  # agent name is TASK-SCOPED (sm-pi-<task-id>) — never a shared global name
  herdr agent start sm-pi-<task-id> --kind pi --pane <root_pane_id> \
    -- --provider amazon-bedrock --model qwen.qwen3-coder-next --thinking medium
  herdr agent prompt sm-pi-<task-id> "<plan>" --wait --timeout 600000
  ```
  `<root_pane_id>` comes from `.result.root_pane.pane_id` of the `herdr worktree create` call (step 2).
  `<task-id>` is the same slug used in the worktree branch (e.g. `add-version-flag`). A task-scoped name
  prevents loop-back fix plans from being routed to a stale agent in a different worktree.
  Do NOT use `herdr-pane.sh spawn` here — it splits from the caller's workspace, orphaning the worktree workspace.
  Use `--thinking medium` (not `off`) — Qwen's reasoning catches edge cases (null guards, trap safety,
  portability) that pure token prediction misses. Use `--thinking high` for security-sensitive or complex logic.
  Pi runs as a lifecycle-tracked herdr agent: if `blocked` (approval/question UI), inspect `herdr agent get/read`
  before deciding what to send — do not advance to Check while the maker is blocked. If `agent_prompt_stalled`
  (agent did not respond to the prompt within 5s), re-inspect agent state before retrying.
  Maker output is always read from `git -C <wt> diff`, not pi's terminal.
  If `HERDR_ENV` is not 1, fall back to headless:
  `cd <wt> && run-round.sh --label sm-pi-<task-id> -- pi --provider amazon-bedrock --model qwen.qwen3-coder-next --thinking medium -p "<plan>"`
  Plan must be fully concrete: exact file paths, function signatures, no branching, step-by-step.

  Note: routing happens at step 2 (Spawn). Steps 0a–0c produce the plan; steps 1–2 create the worktree; step 0d's maker command runs in that worktree.

After either maker path completes, **always proceed to step 4 (Check)** — same pi checker regardless of which maker ran:
`launch-checker.sh --addendum-text "..." --diff-base <base> --repo <wt> -- -p "review the change"` → `verdict.py`.
Checker model: `global.openai.gpt-5.6-terra` (default `SM_CHECKER_MODEL`). Maker ≠ checker invariant holds regardless of which maker path is chosen.

## The loop (run these yourself; the user invokes nothing)

1. **Triage** — classify the task `ship` (produces a diff) vs `scout` (report only; skip the checker and
   the gate), and a rigor tier: `full` (checker + verify-gate + human hold) or `fast` (tests + gate only).
   For a reasoning-heavy question with no tools needed (root-cause, triage, plan review, pre-mortem),
   delegate a one-shot:
   `${CLAUDE_PLUGIN_ROOT}/bin/reason.sh [--model r1|gpt] [--context <file>] "question"` — read its answer, decide.

2. **Spawn** — isolate the maker. Two paths:
   - **Headless / not in herdr:** `read wt branch < <(${CLAUDE_PLUGIN_ROOT}/bin/new-worktree.sh --repo <repo> --task <id>)` — never the primary checkout.
   - **In herdr (`HERDR_ENV=1`):** `herdr worktree create --cwd <repo> --branch sm/<task-id> --base HEAD --label sm-<task-id> --no-focus`
     — creates the git worktree AND a herdr workspace/tab/pane in one call. Read the worktree path from `.result.worktree.path` and the pane ID from `.result.root_pane.pane_id`.

3. **Guard the round** — wrap each maker/checker invocation and track loop health:
   - `${CLAUDE_PLUGIN_ROOT}/bin/run-round.sh --label <id> -- <cmd>` (wall-clock timeout, idle watchdog, audit record even on kill).
   - `${CLAUDE_PLUGIN_ROOT}/bin/loop-guard.sh action --key "<canonical diff/action>"` (aborts a no-progress repeat loop) and
     `${CLAUDE_PLUGIN_ROOT}/bin/loop-guard.sh round` (per-run round cap + global spawn cap; exhaustion reports `budget-limited`, never success).
     `loop-guard.sh reset` on a new task or human interjection.

4. **Check** — after the maker commits, trim bulky logs then run the cross-model checker:
   - `${CLAUDE_PLUGIN_ROOT}/bin/prune-output.sh` on big command output before feeding it in.
   - `${CLAUDE_PLUGIN_ROOT}/bin/launch-checker.sh --addendum-text "TASK/SPEC/HAMMER/INVARIANTS ..." --diff-base <base-ref> --repo <wt> --live-text "<what changed this round + what to focus on>" -- -p "review the change described in the LIVE block"`
     — edit-locked (`--exclude-tools edit,write`), verdict-envelope injected automatically. **Layered, freshest LAST:** (1) static
     eval-tuned discipline, (2) optional lenses, (3) envelope, (4) your **standing** per-task addendum (TASK/SPEC/HAMMER/INVARIANTS —
     stable across the task's rounds), (5) the **LIVE** layer for THIS round. The addendum is the *standard*; the live layer rides *on top* as fresh, current context.
   - **Keep the checker alive, not stale — regenerate the LIVE layer every round.** `--diff-base <ref>` auto-injects the real
     `git diff <ref>..HEAD` (pruned) so the checker always sees exactly what changed NOW — never a pasted, stale diff. After each round,
     save the checker's output to `$SM_LAST_VERDICT` (default `$SM_LOOP_STATE/last-verdict.md`); `launch-checker.sh` auto-injects it the
     next round as "prior verdict — resolve or re-confirm", giving the checker round-to-round memory. Put this round's one-line focus
     (what you just changed, what to hammer now) in `--live-text`. Set the addendum ONCE per task; refresh `--diff-base` / `--live-text` / the saved verdict EACH round.
   - **Pick specialized lenses by task — load only what the diff touches.** Beyond the base correctness
     discipline, choose the role(s) that fit: `redteam` (security-sensitive), `qa` (tests/behavior),
     `reverse-engineer` (unfamiliar/obfuscated/third-party code), `research` (novel/uncertain design, possible
     hallucinated APIs). Read that role's router `${CLAUDE_PLUGIN_ROOT}/bin/lenses/<role>/ROUTER.md` to select
     the specific sub-lenses the diff can reach, then inject them:
     `launch-checker.sh --lens redteam/injection --lens qa/coverage -- -p "..."`. Do NOT dump a whole role;
     load only the sub-lenses that apply — focused context is the point.
   - **No harness? The cross-model check stays intact via a fallback.** If `launch-checker.sh` exits with
     `SM_NO_CHECKER_HARNESS` (or `/secondmate-doctor` reports no checker harness), spawn the checker as a Claude
     sub-agent via the Agent tool on a **different model than the maker**, tell it review-only (no edits, no
     state-changing commands), paste in `${CLAUDE_PLUGIN_ROOT}/bin/checker-prompt.md` +
     `${CLAUDE_PLUGIN_ROOT}/bin/checker-envelope.md` + the selected `bin/lenses/<role>/<sub>.md` files + the
     diff, and require it to end with the `{verdict}` envelope. It is weaker than a cross-vendor harness (same
     model family) but keeps maker ≠ checker and the deterministic verdict. Capture its final message and
     treat it exactly like harness output below.
   - Branch on the verdict deterministically, NOT on the checker's prose:
     `${CLAUDE_PLUGIN_ROOT}/bin/verdict.py <checker-output>` → exit 0 pass / 1 fail / 2 error|refused.
   - **On `fail` — loop back to the maker, never fix inline as supervisor.** The supervisor reads the
     findings, synthesizes a concrete fix plan, then routes it to the task-scoped maker:
     - *Pi herdr maker (still running):* `herdr agent prompt sm-pi-<task-id> "<fix plan>" --wait --timeout 600000`
     - *Pi herdr maker (exited/done):* `herdr agent start sm-pi-<task-id> --kind pi --pane <root_pane_id> -- --provider amazon-bedrock --model qwen.qwen3-coder-next --thinking medium`, then prompt.
     - *Headless pi maker:* `cd <wt> && run-round.sh --label sm-pi-<task-id> -- pi ... --thinking medium -p "<fix plan>"`
     - *Claude maker:* `herdr agent prompt sm-<task-id> "<fix plan>" --wait --timeout 600000`
     The supervisor NEVER writes project code itself — synthesizing the fix plan is analysis, not implementation.
     Every fix round goes through Check with a refreshed `--live-text` and an incremented unique round marker.
   - **On `error` or `refused`** — do not retry via the maker. Inspect the checker output, fix the checker
     invocation (bad args, missing context) or escalate to the human. `refused` always escalates.

5. **Gate** — before integrating anything:
   `${CLAUDE_PLUGIN_ROOT}/bin/verify-gate.sh --worktree <wt> --base <branch> --checked-sha <the exact sha the checker reviewed> [--test "<cmd>"]`
   — integrate only on `PASS`. Passing `--checked-sha` is mandatory: it catches a maker pushing commits after the checker approved.

6. **Hold** — every human-gate decision (merge / risky / outward-facing) is durable, not chat memory:
   `${CLAUDE_PLUGIN_ROOT}/bin/hold.py hold --task <id> --q "..." [--opts "a|b|c"]`, acted on only after
   `${CLAUDE_PLUGIN_ROOT}/bin/hold.py answer <id> --a "..."`. The plugin's SessionStart hook surfaces open holds
   each session, so a restart never drops a pending gate — reconcile any it reports before new work.

8. **Integrate** only after a passing verdict + a `PASS` gate + an answered hold. `scout` tasks stop at a report.

9. **Teardown** — immediately after integration, close everything created for this task:
   ```bash
   herdr worktree remove --workspace <workspace-id>   # removes git worktree + herdr workspace
   git branch -d sm/<task-id>                          # delete the merged branch
   herdr pane close "$mk_pane"                         # maker pane (if visible path was used)
   herdr pane close "$ck"                              # checker pane (if visible path was used)
   ```
   A merged task that leaves a worktree or branch behind is incomplete. The worktree must not outlive its task.

10. **Audit trail** — after teardown, append to `audit/flow.md` and `audit/decision.md` in the **primary checkout**:
   - `audit/flow.md` — which maker path was chosen and why, planner model list if committee ran, round count, outcome.
   - `audit/decision.md` — what the maker decided, what the checker found, every gate auto-approved or escalated and why.
   Append, never rewrite. Commit separately in the primary repo — they do not touch the worktree and cannot stale the checked SHA.
   Both files are `@`-imported in `CLAUDE.md` and auto-loaded into every session as context. Skip for trivial one-shot edits.

## Visible orchestration in herdr (when HERDR_ENV=1)

By default the maker and checker run headless (in-process sub-agent + background scripts) — the captain can't
watch them. Inside herdr, run the loop in VISIBLE side-by-side panes. You stay in your pane and drive the
others via the herdr CLI. First check: `${CLAUDE_PLUGIN_ROOT}/bin/herdr-pane.sh check` (if it fails, use the
headless path). Every split uses `--no-focus` so the captain's focus never moves.

- **Maker pane** — use `spawn` (not `delegate`) to capture the pane ID for cleanup, then drive via `agent prompt`:
  ```bash
  read mk mk_pane < <(${CLAUDE_PLUGIN_ROOT}/bin/herdr-pane.sh spawn \
    --name sm-<task-id> --kind claude --dir right --cwd <worktree> -- --permission-mode acceptEdits)
  [ -n "$mk_pane" ] || { echo "spawn failed — abort" >&2; exit 1; }
  herdr agent prompt sm-<task-id> "/loop-task <goal>" --wait --timeout 600000
  ```
  `spawn` returns `<name> <pane_id>` — guard on `$mk_pane` before prompting to avoid routing to a stale
  agent if spawn fails. If Claude shows a one-time folder-trust prompt, accept it once: `herdr agent send-keys sm-<task-id> enter`. The maker's output is
  its file edits — read them with `git -C <worktree> diff`, not from the pane.
- **Checker pane** — the edit-locked checker, run headless IN the pane so it's visible AND capturable.
  **Must include `--diff-base` and `--repo` so the checker sees the actual diff.** Use a unique per-round
  marker (R1, R2, R3…) to avoid matching stale buffer output from prior rounds:
  ```bash
  ck=$(${CLAUDE_PLUGIN_ROOT}/bin/herdr-pane.sh split down)
  herdr pane run "$ck" "${CLAUDE_PLUGIN_ROOT}/bin/launch-checker.sh \
    --lens qa/coverage --addendum-text '...' \
    --diff-base <base-ref> --repo <wt> \
    --live-text '<what changed this round>' \
    -- -p 'Review the change.' ; echo ___SM_R<N>_DONE_\$?"
  herdr pane wait-output "$ck" --regex "___SM_R<N>_DONE_[0-9]+" --timeout 600000
  herdr pane read "$ck" --source recent-unwrapped --lines 400 > /tmp/sm-checker.out
  ${CLAUDE_PLUGIN_ROOT}/bin/verdict.py /tmp/sm-checker.out
  ```
- **Watch + integrate from your pane** — `herdr agent get/read sm-<task-id>`, `herdr pane read "$ck"`; then the
  usual verify-gate + hold. You can't answer another pane's live prompt, so run any gated command yourself
  in the supervisor context (still a separate context, so maker ≠ checker holds).
- **Clean up ONLY the panes you created**: `herdr pane close "$mk_pane"`, `herdr pane close "$ck"`.

Not in herdr (`HERDR_ENV != 1`)? Use the headless path — in-process maker sub-agent + `run-round.sh`-wrapped
checker. Same loop, same guards, just not visible.

## Not for
Trivial one-shot edits, read-only questions, or work with no verifiable result — do those directly.
