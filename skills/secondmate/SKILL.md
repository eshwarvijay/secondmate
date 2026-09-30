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
- **Top-level supervisor** (you, when a human is directly present) — recognizes the trigger test, dispatches
  a fresh sub-agent-supervisor (see "Dispatch — the standard path" below), watches for progress/staleness
  signals, parses a sub-supervisor's terminal tag via `bin/dispatch-report.py`, relays stuck/hold situations
  to the human verbatim, and otherwise stays free for the human's next input. It never runs the
  maker/checker/gate/hold/merge loop itself once the trigger fires.
- **Sub-agent-supervisor** (dispatched, fresh context) — triage, adjudicate, gate, integrate. Never write
  project code yourself. From here through "Lesson feedback" below, "the supervisor"/"you" means whichever
  supervisor is actually running this SOP — in practice the dispatched sub-supervisor, since dispatch is the
  only path once the trigger test is met.
- **Maker** — implements in an isolated worktree (e.g. a Claude `/loop-task`).
- **Checker** — a *different* model, edit-locked, that reviews the diff and emits a verdict. Its blind
  spots must not correlate with the maker's, so run a different model family than the maker. If no external
  harness is installed, the fallback is a different-model Claude sub-agent (same vendor, weaker, but maker is
  still not the checker) — see the Check step.

**Session guard (sleep prevention):** `caffeinate-guard.sh` is a SESSION-SCOPED process, NOT per-task.
- Primary: call `start` ONCE at the very beginning of a work session/batch (before triaging the first task)
- Also safe (though redundant): you may call `start` again at each task's Spawn step since it is idempotent
- Call `stop` ONCE yourself, after you have confirmed EVERY task/worktree in that batch has been torn down
- Never call `stop` inside per-task teardown — sibling tasks may still be running

## Dispatch — the standard path once the trigger fires

Once a task trips the trigger test (iterative + verifiable + risky/outward-facing), there is exactly ONE
path: the top-level supervisor claims nothing and writes no code itself — it dispatches a **fresh
sub-agent-supervisor** to run the entire SOP below (Plan Committee through Lesson feedback) inside that
sub-supervisor's own, unpolluted context. This holds whether it's the only task at hand (**solo
dispatch** — one fresh sub-supervisor) or one of several genuinely independent tasks handed over together
(**batch dispatch** — up to 10 fresh sub-supervisors, one consolidated hold): solo and batch are the same
mechanism, differing only in how many sub-supervisors get fanned out. "Dispatch mechanics — solo and
batch" later in this file (previously called "Fan-out") gives the exact claim/record/hold/merge steps each
dispatched sub-supervisor follows, and the top-level supervisor's own dispatcher-side responsibilities
(staleness watchdog, relaying stuck/hold situations, parsing `bin/dispatch-report.py`'s exit code).

The top-level supervisor's own job, once it has dispatched, narrows to: recognize the trigger, dispatch,
watch for progress/staleness signals, parse the sub-supervisor's terminal tag, relay stuck/hold situations
to the human verbatim, and otherwise stay free to take the human's next input. It is never the one running
Plan Committee, Triage, Spawn, Guard, Check, Gate, Hold, Integrate, Teardown, Audit trail, or Lesson
feedback — that is entirely the dispatched sub-supervisor's job, described below.

Everything from "Plan Committee" through "Lesson feedback" below is written as instructions **to the
sub-agent-supervisor executing inside its own dispatched context** — "you"/"the supervisor" in that prose
means the sub-supervisor, not the top-level dispatcher.

## Plan Committee (pre-triage, unconditionally for every task)

Before triaging, run the planning committee to gather independent perspectives from multiple models.

**0a — adhd subagent (Claude cognitive frames, you run this):**
Invoke `/adhd` as a Claude sub-agent; save its winning branch to `.secondmate/planning/adhd.md`.

**0b — multi-model planners (parallel, 6 models):**
```
${CLAUDE_PLUGIN_ROOT}/bin/plan-committee.sh --task "<task description>" [--timeout 300]
```
Spawns 6 headless pi planners in parallel (DeepSeek-R1 → failure modes; Qwen3-Next-80B → architecture;
Qwen3-Coder-Next → implementation; Kimi K3 (bedrock cross-region inference profile: global.moonshotai.kimi-k3) → holistic risk; Mistral-Large-3 → security;
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
  After step 2 Spawn creates `<wt>`, start the Claude maker directly on the root_pane from `herdr worktree create`:
  ```bash
  herdr agent start sm-<task-id> --kind claude --pane <root_pane_id> -- --permission-mode auto || { echo "herdr agent start failed — abort" >&2; exit 1; }
  herdr agent prompt sm-<task-id> "Implement: <goal>. You are the maker — write the code, run tests, commit to this worktree, then reply DONE. Do NOT invoke /loop-task or secondmate; the supervisor owns the checker loop. <append the \"Maker prompt closing boilerplate\" block, substituting --task \"<goal>\">" --wait --timeout 600000
  ```
  The root_pane comes from `.result.root_pane.pane_id` of the `herdr worktree create` call. No split needed since the root_pane's cwd is already the worktree. Guard on the agent name before prompting — if the agent fails to start, abort rather than routing to a stale agent. Same `<task-id>` slug as the worktree branch. Give the goal + key constraints; Claude's own reasoning resolves the how — do not pre-specify steps that the maker's thinking can figure out.
- **Simple** (well-specified, pure code, no external deps) → pi maker via herdr (when `HERDR_ENV=1`):
  ```bash
  # Prerequisite: step 2 must have called mark-maker.sh after herdr worktree create (see step 2 for the full sequence)
  # agent name is TASK-SCOPED (sm-pi-<task-id>) — never a shared global name
  herdr agent start sm-pi-<task-id> --kind pi --pane <root_pane_id> \
    -- --provider amazon-bedrock --model qwen.qwen3-coder-next --thinking medium --extension "${CLAUDE_PLUGIN_ROOT}/bin/scope-guard-extension.ts"
  herdr agent prompt sm-pi-<task-id> "<plan> <append the \"Maker prompt closing boilerplate\" block, substituting --task \"<plan>\">" --wait --timeout 600000
  ```
  `<root_pane_id>` comes from `.result.root_pane.pane_id` of the `herdr worktree create` call (step 2), and the
  worktree **must have been marked** by calling `${CLAUDE_PLUGIN_ROOT}/bin/mark-maker.sh --cwd <wt>` BEFORE
  starting this agent (finding #5 fix) — otherwise scope-guard.py won't activate and the maker can access anything.
  `<task-id>` is the same slug used in the worktree branch (e.g. `add-version-flag`). A task-scoped name
  prevents loop-back fix plans from being routed to a stale agent in a different worktree.
  Do NOT use `herdr-pane.sh spawn` here — without --pane, it splits from the caller's current pane (potentially in a different workspace); with --pane, it splits from the supplied pane's workspace.
  Use `--thinking medium` (not `off`) — Qwen's reasoning catches edge cases (null guards, trap safety,
  portability) that pure token prediction misses. Use `--thinking high` for security-sensitive or complex logic.
  Pi runs as a lifecycle-tracked herdr agent: if `blocked` (approval/question UI), inspect `herdr agent get/read`
  before deciding what to send — do not advance to Check while the maker is blocked. If `agent_prompt_stalled`
  (agent did not respond to the prompt within 5s), re-inspect agent state before retrying.
  Maker output is always read from `git -C <wt> diff`, not pi's terminal.
  If `HERDR_ENV` is not 1, fall back to headless:
  `cd <wt> && run-round.sh --label sm-pi-<task-id> -- pi --provider amazon-bedrock --model qwen.qwen3-coder-next --thinking medium --extension "${CLAUDE_PLUGIN_ROOT}/bin/scope-guard-extension.ts" -p "<plan> <append the \"Maker prompt closing boilerplate\" block, substituting --task \"<plan>\">"`

  **Plan format — intent + constraints, not a recipe.** The maker has `--thinking medium/high`; let it reason.
  A good plan gives:
  - **What** to achieve (goal + success condition the checker will verify)
  - **Key constraints** (must not break X, must handle Y edge case, must be idempotent)
  - **Scope boundary** (what's in, what's explicitly out of this increment)

  A good plan does NOT give:
  - Exact file paths or line numbers (the maker reads the repo)
  - Step-by-step execution order (the maker's thinking handles this)
  - Every error-handling case spelled out (that's what `--thinking` is for)

  Pre-specifying every detail replaces the maker's reasoning with yours, which is weaker and wastes the model's thinking budget. The checker is the safety net — trust it.

  Note: routing happens at step 2 (Spawn). Steps 0a–0c produce the plan; steps 1–2 create the worktree; step 0d's maker command runs in that worktree.

After either maker path completes, **always proceed to step 4 (Check)** — same pi checker regardless of which maker ran:
`launch-checker.sh --addendum-text "..." --diff-base <base> --repo <wt> -- -p "review the change"` → `verdict.py`.
Checker model: `global.openai.gpt-5.6-terra` (default `SM_CHECKER_MODEL`). Maker ≠ checker invariant holds regardless of which maker path is chosen.

## The loop (executed inside the dispatched sub-supervisor's own context — steps 1-11)

### Maker prompt closing boilerplate (used by every maker invocation in this file)

Every maker prompt in this file — first-round and fix-round, Claude and pi, herdr and headless, whether
its invocation appears above or below this section — ends with this exact closing, appended right
after the task-specific instruction (`<goal>`/`<plan>`/`<fix plan>`) and before the prompt's closing
quote (and any trailing `--wait --timeout 600000`):

```
Before replying DONE, write/update the round-state handoff file (`${SM_ROUND_STATE:-${SM_LOOP_STATE:-.secondmate}/round-state.md}`). Write it ATOMICALLY (write to a temp file in the same directory, then `mv` over the real path — never a direct partial write). Include the four prose sections you have direct knowledge of: Objective, Active, Blocked, Next Move. The supervisor will populate Completed and Relevant Files from git history when synthesizing a restart; you can leave placeholder text or omit them.

If this task decomposes into checkable sub-goals, also maintain `${SM_ROUND_STATE:-${SM_LOOP_STATE:-.secondmate}}/feature-list.json`: a cumulative, current-state (not append-only) JSON array of `{id, description, status: "pending"|"pass"|"fail", verified_by, round}`, written with the same atomic temp-file+mv idiom as round-state.md above — never a direct partial write. `verified_by` names the concrete command/test/check and its actual result and is required (non-null) whenever status is pass or fail; null is only valid for pending. This file is optional — a single-round task is never required to create it.

Before replying DONE, you must have actually run something — tests, a build, or a live check appropriate to the task — with the result visible in what you write; code inspection alone ("I read it and it looks right") is never sufficient. If feature-list.json exists, its pass/fail sub-goals' `verified_by` citations ARE that evidence. If it doesn't exist, round-state.md's Active or Next Move section must name what you ran and what it showed.

Two conduct rules hold for every round: (1) never tamper with a test to force it to pass — don't weaken, delete, skip, comment out, or rewrite a test or assertion, directly or indirectly (a mock, stub, or fixture that stops it from exercising real behavior counts as tampering too) — unless the task itself asks for a test change; if a test won't pass, suspect the code under test first. (2) keep git hygiene tight — stage only the exact files that are part of the change, by explicit path (never git add with a dot, -A, or -u; never git commit -a); never force-push in any form, including --force-with-lease. If the same approach fails twice in a row, stop and record it in round-state.md's Blocked section instead of trying a third time silently.

Start every invocation — first round, fix round, or restart — with this checklist, in order, before touching any code: (1) read round-state.md and feature-list.json below if present (both already injected just below this line), (2) check `git log` for prior committed work the handoff might not mention, (3) run `git status`, and re-run this project's test/build command if the handoff doesn't already show a fresh result — both files' claims are self-reported, git log and a fresh test run are what corroborate them, (4) only then start new work. On a discrepancy (uncommitted work, an untested claim, git log showing work the handoff omits), reconcile it in round-state.md's Active or Blocked section — do not invent a new escalation signal.

$([ -f "${SM_ROUND_STATE:-${SM_LOOP_STATE:-.secondmate}/round-state.md}" ] && { echo '--- Previous round handoff ---'; cat "${SM_ROUND_STATE:-${SM_LOOP_STATE:-.secondmate}/round-state.md}"; })
$([ -f "${SM_ROUND_STATE:-${SM_LOOP_STATE:-.secondmate}/feature-list.json}" ] && { echo '--- Feature list ---'; cat "${SM_ROUND_STATE:-${SM_LOOP_STATE:-.secondmate}/feature-list.json}"; })
$(${CLAUDE_PLUGIN_ROOT}/bin/lesson-lookup.py --task "<goal|plan|fix plan>" --task-id "<task-id>")
```

Every call site in this file carries a short pointer — *"append the \"Maker prompt closing
boilerplate\" block, substituting `--task \"<X>\"`"* — instead of retyping this block; `<X>` is that
site's own `<goal>`, `<plan>`, or `<fix plan>` text, substituted into the `--task` argument shown
above.

1. **Triage** — classify the task `ship` (produces a diff) vs `scout` (report only; skip the checker and
   the gate), and a rigor tier: `full` (checker + verify-gate + human hold) or `fast` (tests + gate only).
   For a reasoning-heavy question with no tools needed (root-cause, triage, plan review, pre-mortem),
   delegate a one-shot:
   `${CLAUDE_PLUGIN_ROOT}/bin/reason.sh [--model r1|gpt] [--context <file>] "question"` — read its answer, decide.

2. **Spawn** — isolate the maker. Two paths:
   - **Headless / not in herdr:** `read wt branch < <(${CLAUDE_PLUGIN_ROOT}/bin/new-worktree.sh --repo <repo> --task <task-id>)` — never the primary checkout.
     (Already marks the worktree via `mark-maker.sh` internally.) **Call `${CLAUDE_PLUGIN_ROOT}/bin/caffeinate-guard.sh start` once per session/batch** to prevent system sleep during all tasks in that batch — idempotent, safe to call per-task.
   - **In herdr (`HERDR_ENV=1`):** 
     ```bash
     result=$(herdr worktree create --cwd <repo> --branch sm/<task-id> --base HEAD --label sm-<task-id> --no-focus)
     wt=$(echo "$result" | jq -r '.result.worktree.path')
     root_pane=$(echo "$result" | jq -r '.result.root_pane.pane_id')
     ${CLAUDE_PLUGIN_ROOT}/bin/mark-maker.sh --cwd "$wt"  # REQUIRED: mark before starting the maker
     ${CLAUDE_PLUGIN_ROOT}/bin/sync-worktree-skills.sh --primary <repo> --worktree "$wt"  # copy gitignored .claude/skills/ into the new worktree
     ${CLAUDE_PLUGIN_ROOT}/bin/caffeinate-guard.sh start  # prevent sleep during session execution
     ```
     Creates the git worktree AND a herdr workspace/tab/pane in one call. **Must call mark-maker.sh** before starting
     any maker agent in this worktree (finding #5 fix) — otherwise scope-guard.py won't activate.
     **Must call `${CLAUDE_PLUGIN_ROOT}/bin/caffeinate-guard.sh start`** to prevent system sleep during the session (default 8-hour ceiling via -t).
     **Must call `sync-worktree-skills.sh`** too: project-local `.claude/skills/` is commonly gitignored, so neither `git worktree add` (used internally by `herdr worktree create`) nor `herdr worktree create` itself ever brings it into a fresh worktree on their own.

3. **Guard the round** — wrap each maker/checker invocation and track loop health:
   - `${CLAUDE_PLUGIN_ROOT}/bin/run-round.sh --label <id> -- <cmd>` (wall-clock timeout, idle watchdog, audit record even on kill).
   - `${CLAUDE_PLUGIN_ROOT}/bin/loop-guard.sh action --key "<canonical diff/action>"` and
     `${CLAUDE_PLUGIN_ROOT}/bin/loop-guard.sh round` (per-run round cap + global spawn cap; exhaustion reports `budget-limited`, never success).
     `loop-guard.sh reset` on a new task or human interjection.
   **Exit codes for `loop-guard.sh action`:**
     - `0` = ok, continue (n < 3; silent, no output).
     - `5` = restart recommended (3 <= n < ABORT_REPEATS): the supervisor should kill the maker's herdr agent (e.g., `herdr agent stop sm-<task-id>` or terminate the agent in the pane) and start a fresh one with the same task-scoped name, prompting it with the `round-state.md` handoff content.
     - `3` = hard abort (n >= ABORT_REPEATS): escalate to human intervention.
     - `4` = budget exhausted (from `round` subcommand): unchanged behavior.
     **Note:** `loop-guard.sh` is a pure read-only signal generator; it never kills or restarts anything.
     The ACTOR is the supervisor, who interprets the exit code and takes action accordingly.

4. **Check** — after the maker commits, trim bulky logs then run the cross-model checker:
   - **Strict rule: when `HERDR_ENV=1`, the checker MUST run in a visible herdr pane — headless is prohibited.** Use the "Checker pane" recipe under "Visible orchestration in herdr" below, not the plain invocation shown in this step. The plain `launch-checker.sh` call below is ONLY for when `HERDR_ENV` is not `1`, or `${CLAUDE_PLUGIN_ROOT}/bin/herdr-pane.sh check` fails.
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
     `${CLAUDE_PLUGIN_ROOT}/bin/verdict.py <checker-output>` → exit 0 pass / 1 fail / 2 error|refused. When lenses were injected via `--lens`, add `--lenses <comma-separated-list>` to cross-check the envelope's `lens_coverage` field (the checker is told each lens's exact name and should report `{"lens_coverage": {"<name>": true, ...}}`). A missing lens triggers `ambiguous` (exit 2). Also for `fail` verdicts, findings must contain file:line tokens or the explicit escape hatch `[NOLOC]`; invalid findings trigger `ambiguous`.
   - **On `fail` — loop back to the maker, never fix inline as supervisor.** The supervisor reads the
     findings, synthesizes a concrete fix plan, then routes it to the task-scoped maker:
     - *Pi herdr maker (still running):* `herdr agent prompt sm-pi-<task-id> "<fix plan> <append the \"Maker prompt closing boilerplate\" block, substituting --task \"<fix plan>\">" --wait --timeout 600000`
     - *Pi herdr maker (exited/done):* `herdr agent start sm-pi-<task-id> --kind pi --pane <root_pane_id> -- --provider amazon-bedrock --model qwen.qwen3-coder-next --thinking medium --extension "${CLAUDE_PLUGIN_ROOT}/bin/scope-guard-extension.ts"`, then prompt with the same fix plan and checklist.
     - *Headless pi maker:* `cd <wt> && run-round.sh --label sm-pi-<task-id> -- pi --provider amazon-bedrock --model qwen.qwen3-coder-next --thinking medium --extension "${CLAUDE_PLUGIN_ROOT}/bin/scope-guard-extension.ts" -p "<fix plan> <append the \"Maker prompt closing boilerplate\" block, substituting --task \"<fix plan>\">"`
     - *Claude maker:* `herdr agent prompt sm-<task-id> "You are the maker. Do NOT invoke /loop-task or secondmate. <fix plan> <append the \"Maker prompt closing boilerplate\" block, substituting --task \"<fix plan>\">" --wait --timeout 600000`
     The supervisor NEVER writes project code itself — synthesizing the fix plan is analysis, not implementation.
     Every fix round goes through Check with a refreshed `--live-text` and an incremented unique round marker.
     **Restart amplio-style hybrid:** When the supervisor restarts a maker mid-round (due to `loop-guard.sh` exit-5 restart signal,
     timeout, or idle-watchdog) rather than the maker reaching DONE naturally, the supervisor itself synthesizes the
     deterministic `Completed` and `Relevant Files` sections from `git log` and `git diff` in the worktree (and
     `bin/run-round.sh`'s own audit record if one exists for that round) before restarting the fresh maker.
     The maker owns only the four prose sections it has direct knowledge of: Objective, Active, Blocked, Next Move.
     This hybrid approach ensures deterministic history while giving the maker room to provide the 'why' when it
     gets the chance to write it after a restart.
   - **On `error` or `refused`** — do not retry via the maker. Inspect the checker output, fix the checker
     invocation (bad args, missing context) or escalate to the human. `refused` always escalates.
   - **Log the round.** After every checker verdict (pass, fail, error, or refused), append a metrics
     record: `${CLAUDE_PLUGIN_ROOT}/bin/log-round.sh --task <id> --round <N> --maker claude|pi --verdict <verdict> [--tag <finding-category>]... [--lesson-id <id>]... [--cost <n>] [--duration <n>]`.
     Supply one `--tag` per recurring finding category you'd tag it with in this task's decision entry anyway
     (e.g. `real-bug`, `scope-creep`, `fake-test`, `not-committed`) — this is structured data alongside the
     prose audit trail, not a replacement for it. `--lesson-id` is optional and repeatable too, mirroring
     `--tag` — pass the lesson ids `lesson-lookup.py` actually injected this round if you have them handy,
     for the same reason step 11 later reads the injection ledger: to know which lessons appeared. `--cost`/
     `--duration` are optional, only if already at hand (e.g. from a herdr pane's own cost/elapsed display) —
     never scrape or parse for them.

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
   herdr pane close "$ck"                              # checker pane (if visible path was used) - close BEFORE workspace removal
   herdr worktree remove --workspace <workspace-id>   # removes git worktree + herdr workspace
   git branch -d sm/<task-id>                          # delete the merged branch
   ```
   A merged task that leaves a worktree or branch behind is incomplete. The worktree must not outlive its task.

   Then run `${CLAUDE_PLUGIN_ROOT}/bin/teardown-check.sh --task-id <task-id> --repo <repo>` as an advisory
   confirmation — it reports whether a worktree, branch, herdr pane/agent, or claim-ledger entry for this
   task-id is still around (exit 0 = clean, nonzero = something is still present, per its own report). It
   never blocks or fails anything by itself; a nonzero report just means look again before moving on.

   **IMPORTANT:** `caffeinate-guard.sh stop` is SESSION-SCOPED, not per-task. Call it ONCE yourself, directly,
   only after you have confirmed EVERY task/worktree in that batch has been torn down. Never call `stop` inside
   a task's per-task teardown — sibling tasks may still be running and need sleep prevention.

10. **Audit trail** — after teardown, in the **primary checkout**, file one entry per task via
   `${CLAUDE_PLUGIN_ROOT}/bin/audit-log.py add --type flow --task <task-id> --date <YYYY-MM-DD> --title "<title>" --body-file <path>`
   and the same with `--type decision`:
   - `flow` — which maker path was chosen and why, planner model list if committee ran, round count, outcome.
   - `decision` — what the maker decided, what the checker found, every gate auto-approved or escalated and why.
   This writes the entry verbatim to its own file under `audit/flow/`/`audit/decision/` and regenerates the
   bounded `audit/INDEX.md` — never hand-edit `audit/INDEX.md`, and there is no `audit/flow.md`/`audit/decision.md`
   monolith to append to anymore. Commit separately in the primary repo — this does not touch the worktree and
   cannot stale the checked SHA. Only the generated, size-capped `audit/INDEX.md` is `@`-imported in
   `CLAUDE.md` and auto-loaded into every session — never the per-task files themselves. Skip for trivial
   one-shot edits.

11. **Lesson feedback** — in the SAME commit as step 10's `bin/audit-log.py add` update
   (directly in the primary checkout, never inside the maker's worktree), tag whichever injected lessons
   you have real grounds to judge. Check the injection ledger (`$SM_LESSON_LEDGER`, default anchored
   under `.secondmate/lesson-injections.jsonl`) for this task-id's entries to see which lesson ids were
   actually shown across the task's rounds, then for each one:
   `${CLAUDE_PLUGIN_ROOT}/bin/lesson-lookup.py tag --lesson-id <id> --outcome helpful|harmful`.
   Tag a lesson only when you have direct, specific evidence FROM THIS TASK that the mistake it
   describes recurred anyway or was concretely avoided because of it — leaving a lesson untagged is
   always fine, tagging on a hunch is not, since an ungrounded tag corrupts the signal every future
   task's lesson lookup relies on. This is your own observation of this one task, never an automated
   correlation against `audit/metrics.jsonl`, `verdict.py` output, or any other history — no such
   correlation logic exists here, and none should be built.

## Dispatch mechanics — solo and batch

Dispatch is the ONE path once the trigger test is met (see "Dispatch — the standard path" above) — not an
opt-in exception layered on top of some other default. It comes in exactly two sizes, same mechanism,
never mixed in one Agent-tool call:

- **Solo dispatch** — one task, one fresh sub-agent-supervisor (e.g. to keep the top-level dispatcher's own
  context clean, or to run one task under independent triage/routing/verdict judgment). That one
  sub-supervisor still owns its own hold and its own merge — a consolidated batch hold buys nothing for a
  batch of one.
- **Batch dispatch** — a human hands the top-level supervisor several genuinely independent tasks (up to
  10) to run concurrently. **ONE genuine human decision per batch, not one per task-id.**

Any task beyond batch dispatch's 10-task cap queues sequentially for the next dispatch.

### Solo dispatch — one task, one fresh sub-supervisor

Make ONE Agent-tool call carrying exactly 1 tool-use block, launching a **FRESH** sub-agent — never
`fork` (which inherits the dispatcher's own conversation context; the sub-supervisor needs a clean,
unpolluted one). **Name the Agent-tool call `sm-<task-id>`** — never leave `name` unset. Instruct it to:

1. Claim first (`bin/claim-ledger.py claim --task-id <task-id> --owner sm-<task-id>`), never `--steal`
   itself; abort with `SM_REFUSED:claim-failed` on failure. Immediately after a successful claim, record
   the checkpoint: `bin/progress-ledger.py record --task-id <task-id> --owner sm-<task-id> --phase claimed`.
2. Derive every downstream name deterministically from `<task-id>` (`sm/<task-id>` branch,
   `sm-<task-id>`/`sm-pi-<task-id>` agent name, `root_pane` from `herdr worktree create`).
3. Run the existing solo SOP completely untouched — plan-committee, maker routing, checker rounds,
   verify-gate — recording the SAME checkpoints a batch dispatch's sub-supervisor records (just without a
   `--batch-id`, since a solo dispatch has no batch to correlate against): `bin/progress-ledger.py record
   --task-id <task-id> --owner sm-<task-id> --phase maker_started` immediately after the maker begins
   running, and `--phase checker_round` immediately after each checker round completes (once per round).
4. Once verify-gate passes, record the terminal checkpoint — `bin/progress-ledger.py record --task-id
   <task-id> --owner sm-<task-id> --phase verify_gate_pass --checked-sha <checked-sha>
   --checker-verdict-path <path>` — then open its OWN `bin/hold.py hold --task <task-id> --q "..." --sha
   <checked-sha>` and wait for a genuine human answer — never assume, never auto-answer, never defer that
   judgment call to the dispatcher.
5. Only once answered, call `bin/merge-sequencer.sh` itself with its own claimed
   `--branch`/`--worktree`/`--checked-sha` (queueing behind a sibling's concurrent merge on the same
   `--repo` is the singleton lock working as intended, not a bug).
6. Release its claim on every terminal path (`bin/claim-ledger.py release --task-id <task-id> --owner
   sm-<task-id> --token <token>`).
7. Emit exactly one completion tag, on its own line, as its literal final output: `SM_DONE_MERGED:<sha>`,
   `SM_STUCK_NEED_HUMAN:<reason>`, or `SM_REFUSED:<reason>`.

The dispatcher parses that final text with `bin/dispatch-report.py` (never re-reading the prose itself)
and acts only on the exit code: `0` = `SM_DONE_MERGED` (integration done), `1` = `SM_REFUSED` (relay the
reason), `2` = `SM_STUCK_NEED_HUMAN` (relay the reason verbatim, never resolve it yourself), `3` = no tag
found (treat as an escalation-worthy parse failure).

### Batch dispatch — up to 10 concurrent, one consolidated hold

**Mechanism.** Make ONE Agent-tool call carrying AT MOST 10 tool-use blocks — a **hard cap**, an explicit
constant (`N=10`), not a tunable parameter, matching how the earlier `N=2` cap was itself a non-tunable
choice. There is no N>10 variant; if there are more than 10 independent tasks, run 10 now and queue the
rest for the next batch. Each tool-use block launches a **FRESH** sub-agent — never `fork`, same
contamination rationale as solo dispatch. **Name each Agent-tool call `sm-<task-id>`.**

**Before fanning out, mint a `<batch-id>` for this batch — a UUID, e.g. `python3 -c "import uuid;
print(uuid.uuid4())"` or `uuidgen`, NEVER a timestamp-derived label** (a timestamp is a realistic
collision: two dispatcher runs close in time can easily land on the same value). This is the CORRELATION
KEY every sub-supervisor in this batch carries on every one of its own `progress-ledger.py record` calls
(step (c) below) — it is what lets step (e)'s restart-reconstruction tell "ready for THIS batch" apart
from an unrelated batch's, or a solo dispatch's task's, own `verify_gate_pass` row.
Tell every sub-supervisor its shared `<batch-id>` in its own prompt.

`progress-ledger.py` itself enforces that a given task-id's `--batch-id`, once first recorded, is
IMMUTABLE for that task-id's lifetime (a later `record` call for the SAME task-id supplying a different
value is rejected outright) — this closes batch-id drift for one task-id reused/misused over its own
history. **It does NOT, and cannot, prevent two genuinely different, freshly-claimed task-ids from two
independent dispatcher runs from coincidentally binding to the identical `<batch-id>` value** — no local
ledger can distinguish "intentionally co-batched" from "accidentally collided" for two task-ids that are
each individually self-consistent, short of a distributed uniqueness registry (explicitly out of scope —
see this section's own "no 1000-task hardening" boundary). Minting from a UUID makes that collision
practically negligible; it is not a structural guarantee, and this is deliberate, not an oversight.

**Each sub-supervisor's prompt must instruct it to, in this order:**

a. **Claim first, as its literal first action, then record it.** Run `bin/claim-ledger.py claim --task-id
   <task-id> --owner sm-<task-id>` before anything else. If the claim fails, abort immediately and emit
   `SM_REFUSED:claim-failed` as its final output — do not proceed, do not retry, do not fall back to
   `--steal`. `--steal` is a human-supervised override and stays exactly that under this pattern too: a
   sub-supervisor must never call it itself. Immediately after a successful claim, run
   `bin/progress-ledger.py record --task-id <task-id> --owner sm-<task-id> --phase claimed --batch-id
   <batch-id>`.

b. **Derive every downstream name deterministically from `<task-id>`, using this repo's own existing
   convention — never invent a new one:**
   - branch: `sm/<task-id>`
   - worktree label / agent name: `sm-<task-id>` (Claude maker) or `sm-pi-<task-id>` (pi maker)
   - pane: whatever `herdr worktree create` returns as `.result.root_pane.pane_id` — never independently
     named or guessed.

c. **Run the existing solo secondmate SOP completely untouched, recording checkpoints along the way** —
   plan-committee, maker routing, checker rounds, verify-gate, exactly as described everywhere above.
   This pattern changes nothing about how a single task runs, only how it gets launched and how its
   verify-gate PASS gets turned into a merge. At these points, run `bin/progress-ledger.py record
   --task-id <task-id> --owner sm-<task-id> --phase <phase> --batch-id <batch-id>` (the SAME `<batch-id>`
   on every call, per the mint-once-per-batch step above):
   - `--phase maker_started` immediately after its maker begins running.
   - `--phase checker_round` immediately after each checker round completes (once per round).
   - `--phase verify_gate_pass` once verify-gate has passed — the terminal checkpoint. ALWAYS also pass
     `--checked-sha <checked-sha>` and `--checker-verdict-path <path>` here (the dispatcher's batch close
     reads both off this exact row — `--checker-verdict-path` is what `hold.py`'s batch digest is
     machine-derived from, see step (e) below).

d. **STOP once that checkpoint is recorded — do NOT open a hold, do NOT self-merge.** Under this batch
   trigger the merge-or-not judgment is ONE decision for the whole batch, made by the dispatcher's
   consolidated hold below, not N separate per-task decisions. **Do NOT release its claim either** — the
   claim stays open (it is the dispatcher's own later record of "this task-id is still mine to
   merge-or-rework"; releasing it here would let anything re-claim a task-id that's actually just waiting
   on a human). Emit `SM_READY_UNMERGED:<checked-sha>` as its literal final output and stop.
   On a refusal or stuck path instead (claim never succeeded, or genuinely wedged before reaching the
   gate), behave exactly as solo dispatch does: release the claim and emit `SM_REFUSED:<reason>` or
   `SM_STUCK_NEED_HUMAN:<reason>`.

**The dispatcher's own role, once it has fanned out a batch:**

e. **Collect ready task-ids, ledger-driven, never from your own in-memory batch state.** Poll (on a
   `ScheduleWakeup`-driven schedule, never continuously) with:
   ```
   ${CLAUDE_PLUGIN_ROOT}/bin/progress-ledger.py ready --batch-id <batch-id>
   # one JSON line per task-id whose latest phase is the terminal verify_gate_pass AND whose own
   # terminal row was recorded under THIS exact --batch-id, each carrying its own
   # checked_sha/checker_verdict_path; always exits 0 (this is the wanted signal, not an error).
   ```
   `--batch-id` is the correlation key from the mint-once-per-batch step above — without it, `ready` would
   report EVERY task-id anywhere at `verify_gate_pass`, including an unrelated batch's or a single-task-
   solo dispatch task's own ready row that just happens to be sitting there awaiting its own
   individual hold; filtering by `--batch-id` is what keeps this batch's consolidated hold from folding in
   a task-id that was never part of it, AS LONG AS that task-id's own batch-id binding is internally
   consistent (see the mint-once-per-batch step's own honest caveat above — this is NOT a distributed-
   uniqueness guarantee against two independent dispatchers coincidentally picking the same `<batch-id>`
   for two genuinely different, freshly-claimed task-ids; UUID minting makes that practically negligible,
   not structurally impossible). This is also why batch-close survives a dispatcher restart/crash
   mid-batch: nothing about "which task-ids are ready, for THIS batch" lives only in this conversation's
   memory — a dispatcher that comes back after a crash need only remember (or re-derive) the same
   `<batch-id>` label to reconstruct that same set (subject to the same honest caveat). Cross-check against
   `bin/claim-ledger.py status`'s own currently-OPEN claims too — anything already merged and released
   from a prior round of this same batch drops out on its own, since its claim is gone.

f. **Close the batch at the cap or a bounded TTL, whichever comes first — never wait indefinitely for a
   straggler.** The batch is DONE (close now) once every task-id fanned out in it has reached a terminal
   `dispatch-report.py` exit code (ready, refused, or stuck — the cap, since a batch never exceeds 10, is
   reached by construction once everyone's finished). Otherwise, pick a TTL (seconds, generous relative to
   a normal round) for how long you're willing to wait for the slowest task-id in the batch, and reuse the
   EXACT SAME staleness primitive for two purposes at once, both against that TTL:
   ```
   ${CLAUDE_PLUGIN_ROOT}/bin/progress-ledger.py stale --threshold-seconds <batch-close-TTL> --task-id <id-1> ...
   # a task-id still mid-loop (never reached any terminal tag) -> "stale"/"no_progress_recorded": relay to
   #   the human verbatim, exactly like the single-task watchdog below.
   # a task-id already at verify_gate_pass, sitting "ready, awaiting batch close" too long because a
   #   SIBLING task-id in the batch is the slow one -> ALSO reported "stale" here (its phase hasn't
   #   advanced since verify_gate_pass, which is exactly what this reuse of `stale` is for) -> this is the
   #   auto-escalation for a ready task-id rotting in limbo: relay it to the human too, then close the
   #   batch anyway with whoever is ready right now.
   ```
   On TTL expiry, close the batch with whatever `ready` reports at that moment; any task-id still mid-loop
   folds into a LATER batch once it finishes (or gets manually reclaimed if a human judges it abandoned).
   No new mechanism beyond `stale`+`ready` is needed for this — the cap/TTL decision is dispatcher logic,
   not a new ledger primitive.

g. **Open ONE consolidated batch hold**, entries built from every task-id `ready` reported at close time:
   ```
   # write a JSON file: [{"task_id":..., "checked_sha":..., "checker_verdict_path":...}, ...]
   ${CLAUDE_PLUGIN_ROOT}/bin/hold.py hold --task "<batch-label>" --q "merge which of: <task-id-1>, <task-id-2>, ...?" \
     --entries-file <that JSON file>
   ```
   Every entry's `checker_verdict_path` MUST resolve to a real, parseable verdict envelope — `hold.py`
   rejects the WHOLE call (nonzero exit, no ledger write) otherwise, never opening a hold with no real
   verdict behind an entry's digest. `hold.py` itself derives a one-line, machine-sourced digest per entry
   straight from that real envelope — its `verdict`, findings count, the distinct files those findings
   flagged (a blast-radius proxy), and `lens_coverage`'s own lens names (the closest thing the envelope
   has to a category/tag concept) — never typed fresh by whoever opens the hold, so the human's summary is
   provably sourced from the real verdict. **Wait for a genuine human
   answer, never self-answer, no exceptions** — including this batch hold itself. A clean `conflicts`
   check between two task-ids' scopes is signal to SHOW in the digest if you have it, never a reason to
   skip the human step.

h. **The answer is structured, not freeform prose:**
   ```
   ${CLAUDE_PLUGIN_ROOT}/bin/hold.py answer <hold-id> --approve "<task-id>,<task-id>,..." --reject "<task-id>,..."
   # every task-id in the batch's own entries must appear in exactly one of --approve/--reject.
   ```

i. **The dispatcher — never an individual sub-supervisor — sequences the actual merges and teardowns for
   every APPROVED task-id, one at a time, using an argv array for any loop over them (never shell-string
   interpolation, matching claim-ledger.py's/merge-sequencer.sh's own hygiene):**
   1. `bin/merge-sequencer.sh --repo <repo> --worktree <worktree> --branch sm/<task-id> --base main
      --checked-sha <that entry's checked_sha>`.
   2. On success: `herdr worktree remove`, delete branch `sm/<task-id>`, `bin/claim-ledger.py release
      --task-id <task-id> --owner sm-<task-id> --token <token>` (the dispatcher needs the token the
      sub-supervisor's own `claim` call printed — carry it forward from step (a)'s launch, or have the
      sub-supervisor report it in its final text alongside the tag), and confirm with
      `bin/teardown-check.sh --task-id <task-id>`.
   3. On a REJECTED task-id: do nothing to its claim, worktree, or branch — it stays exactly as-is,
      `claimed, needs rework`, never silently released, never ambiguous. The next round for that task-id
      resumes in the SAME worktree/claim (this is ordinary rework, not a special case).

**Dispatcher exit-code contract (`bin/dispatch-report.py`):**
```
${CLAUDE_PLUGIN_ROOT}/bin/dispatch-report.py <sub-supervisor-final-output-file>
# exit 0 = SM_DONE_MERGED     -> (solo dispatch only) integration for that task-id is already done
# exit 1 = SM_REFUSED         -> relay the refusal reason to the human, task-id never started
# exit 2 = SM_STUCK_NEED_HUMAN -> relay the reported reason verbatim to the human; do not resolve it yourself
# exit 3 = no tag found at all -> treat as a parse failure and escalate; do not guess what happened
# exit 4 = SM_READY_UNMERGED  -> (batch dispatch only) reached verify-gate PASS, awaiting this batch's hold —
#                                 NOT yet merged; never conflate with exit 0
```

**Required for every dispatch, solo or batch: schedule a staleness watchdog for every outstanding task-id,
once fanned out.** Immediately after launching, and again on every `ScheduleWakeup` firing until every fanned-out
task-id has reached a terminal `dispatch-report.py` exit code, run:

```
bin/progress-ledger.py stale --threshold-seconds <N> --task-id <task-id-1> [--task-id <task-id-2>]
# exit 0, no output   -> every given task-id has reported progress within the threshold; nothing to do.
# exit 1, one JSON line per hit -> {"task_id":..., "status":"no_progress_recorded"} (never even reported
#   its first "claimed" checkpoint) or {"task_id":..., "status":"stale", "phase":..., "last_ts":...,
#   "age_seconds":...} (hasn't advanced past that phase in over N seconds).
```

Pick `<N>` (a threshold in seconds) generously relative to how long a normal round takes in this
repo — long enough that a merely-slow-but-alive checker round doesn't false-positive. On any hit, **relay
it to the human verbatim** — task-id, phase, age — exactly like the `SM_STUCK_NEED_HUMAN` relay above.
**Never auto-restart, never auto-`--steal`, never treat a hit as a confirmed crash and clean up on your
own.** This is scheduled *detection*, not real-time monitoring: it can only notice that a task-id hasn't
self-reported in a while, on whatever cadence you choose to re-check — it cannot distinguish "dead" from
"alive but wedged on something slow that just hasn't hit its next checkpoint yet." That ambiguity is a
hard platform limitation (Claude Code gives a dispatcher no way to poll an Agent-tool background
sub-agent's liveness from outside), not a shortcut being deferred here. (This same `stale` call, with a
different, larger threshold, is also how batch dispatch's batch-close TTL escalation works — see step (f)
above; it is not a second mechanism.)

**Named limitation — detection now exists (self-reported, on a schedule); automatic recovery still does
not.** `bin/progress-ledger.py` closes the *visibility* half of the original gap: a sub-supervisor that
dies without ever recording `verify_gate_pass` will eventually show up as `stale` or
`no_progress_recorded` the next time the dispatcher's watchdog runs `stale`. It does **not** close the
*recovery* half, by the same design stance as `claim-ledger.py`'s own disclosure: no automated
liveness/heartbeat/TTL check decides anything on its own, no claim is ever automatically released, no
worktree is ever automatically torn down, and a `stale` hit is never itself proof of a crash — only a
signal that a human should go look. A human must notice the relayed hit and manually run
`bin/claim-ledger.py release` (or, if truly abandoned, `--steal` with a reason) plus manual worktree
teardown, exactly as before. And detection is only as good as the watchdog's own cadence: a dispatcher
that stops calling `stale` (or an Agent-tool session that ends without a live wakeup ever firing) gets no
signal either — the same gap as before this primitive existed, just narrowed to "when the dispatcher
itself is still polling" rather than "never."

**Explicitly out of scope for batch dispatch, by design, not an oversight:** no `--preflight-only`/rebase
wiring for mid-batch staleness (the TTL above already bounds that exposure — a documented future
enhancement, not this one); no "batch by scope-safety via `conflicts`-check" sizing policy (ship the
count/TTL version above); a passing `claim-ledger.py conflicts` check is NEVER a substitute for the human
hold, only a signal to show inside its digest; no multi-tenant auth/ownership model (single-operator,
local-git); no 1000-task hardening (the cap is an explicit 10, hard, not tunable).

## Visible orchestration in herdr (when HERDR_ENV=1)

**Strict rule: whenever `HERDR_ENV=1`, the checker MUST run in a visible pane — headless checker execution is
prohibited in that case**, not just an optional alternative (see step 4's "Check" section above). The maker
runs directly on the worktree's root_pane the same way. You stay in your pane and drive the others via the
herdr CLI. First check: `${CLAUDE_PLUGIN_ROOT}/bin/herdr-pane.sh check` (if it fails — and only then — fall
back to the headless path). Every split uses `--no-focus` so the captain's focus never moves.

- **Maker pane** — start the Claude maker directly on the root_pane from `herdr worktree create` (no split needed since the root_pane's cwd is already the worktree), then drive via `agent prompt`:
  ```bash
  herdr agent start sm-<task-id> --kind claude --pane <root_pane_id> -- --permission-mode auto || { echo "herdr agent start failed — abort" >&2; exit 1; }
  herdr agent prompt sm-<task-id> "Implement: <goal>. You are the maker — write the code, run tests, commit to this worktree, then reply DONE. Do NOT invoke /loop-task or secondmate; the supervisor owns the checker loop. <append the \"Maker prompt closing boilerplate\" block, substituting --task \"<goal>\">" --wait --timeout 600000
  ```
  If Claude shows a one-time folder-trust prompt, accept it once: `herdr agent send-keys sm-<task-id> enter`. The maker's output is
  its file edits — read them with `git -C <worktree> diff`, not from the pane.
- **Checker pane** — the edit-locked checker, run headless IN the pane so it's visible AND capturable.
  Start by splitting off the SAME dedicated workspace's root_pane (not off the supervisor's pane):
  ```bash
  ck=$(${CLAUDE_PLUGIN_ROOT}/bin/herdr-pane.sh split --pane <root_pane_id> --dir down)
  # Write the full checker invocation to a script file first — herdr pane run's argv-to-PTY-line
  # reconstruction does not preserve shell quoting for multi-token/multi-command strings
  cat > /tmp/checker-<task-id>-r<N>.sh << SCRIPT_EOF
${CLAUDE_PLUGIN_ROOT}/bin/launch-checker.sh \
  --lens qa/coverage --addendum-text '...' \
  --diff-base <base-ref> --repo <wt> \
  --live-text '<what changed this round>' \
  -- -p 'Review the change.' ; echo ___SM_R<N>_DONE_\$?
SCRIPT_EOF
  herdr pane run "$ck" bash /tmp/checker-<task-id>-r<N>.sh
  herdr pane wait-output "$ck" --regex "___SM_R<N>_DONE_[0-9]+" --timeout 600000
  herdr pane read "$ck" --source recent-unwrapped --lines 400 > /tmp/sm-checker.out
  ${CLAUDE_PLUGIN_ROOT}/bin/verdict.py --lenses qa/coverage /tmp/sm-checker.out
  ```
- **Watch + integrate from your pane** — `herdr agent get/read sm-<task-id>`, `herdr pane read "$ck"`; then the
  usual verify-gate + hold. You can't answer another pane's live prompt, so run any gated command yourself
  in the supervisor context (still a separate context, so maker ≠ checker holds).
- **Clean up ONLY the panes you created**: `herdr pane close "$ck"` (no `$mk_pane` to close since the maker ran on the root_pane directly).

  **IMPORTANT:** `caffeinate-guard.sh stop` is SESSION-SCOPED, not per-task. Call it ONCE yourself, directly,
  only after you have confirmed EVERY task/worktree in that batch has been torn down. Never call `stop` inside
  a task's per-task teardown — sibling tasks may still be running and need sleep prevention.

Not in herdr (`HERDR_ENV != 1`)? Use the headless path — in-process maker sub-agent + `run-round.sh`-wrapped
checker. Same loop, same guards, just not visible.

## Not for
Trivial one-shot edits, read-only questions, or work with no verifiable result — do those directly.
