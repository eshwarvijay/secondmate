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

## The loop (run these yourself; the user invokes nothing)

1. **Triage** — classify the task `ship` (produces a diff) vs `scout` (report only; skip the checker and
   the gate), and a rigor tier: `full` (checker + verify-gate + human hold) or `fast` (tests + gate only).
   For a reasoning-heavy question with no tools needed (root-cause, triage, plan review, pre-mortem),
   delegate a one-shot:
   `${CLAUDE_PLUGIN_ROOT}/bin/reason.sh [--model r1|gpt] [--context <file>] "question"` — read its answer, decide.

2. **Spawn** — isolate the maker:
   `read wt branch < <(${CLAUDE_PLUGIN_ROOT}/bin/new-worktree.sh --repo <repo> --task <id>)` — never the primary checkout.

3. **Guard the round** — wrap each maker/checker invocation and track loop health:
   - `${CLAUDE_PLUGIN_ROOT}/bin/run-round.sh --label <id> -- <cmd>` (wall-clock timeout, idle watchdog, audit record even on kill).
   - `${CLAUDE_PLUGIN_ROOT}/bin/loop-guard.sh action --key "<canonical diff/action>"` (aborts a no-progress repeat loop) and
     `${CLAUDE_PLUGIN_ROOT}/bin/loop-guard.sh round` (per-run round cap + global spawn cap; exhaustion reports `budget-limited`, never success).
     `loop-guard.sh reset` on a new task or human interjection.

4. **Check** — after the maker commits, trim bulky logs then run the cross-model checker:
   - `${CLAUDE_PLUGIN_ROOT}/bin/prune-output.sh` on big command output before feeding it in.
   - `${CLAUDE_PLUGIN_ROOT}/bin/launch-checker.sh --addendum-text "TASK/HAMMER: ..." -- -p "<review prompt + diff>"`
     — edit-locked (`--exclude-tools edit,write`), with the verdict-envelope contract injected automatically.
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
     `${CLAUDE_PLUGIN_ROOT}/bin/verdict.py <checker-output>` → exit 0 pass / 1 fail / 2 error|refused. On fail/error, hand back to the maker.

5. **Gate** — before integrating anything:
   `${CLAUDE_PLUGIN_ROOT}/bin/verify-gate.sh --worktree <wt> --base <branch> --checked-sha <the exact sha the checker reviewed> [--test "<cmd>"]`
   — integrate only on `PASS`. Passing `--checked-sha` is mandatory: it catches a maker pushing commits after the checker approved.

6. **Hold** — every human-gate decision (merge / risky / outward-facing) is durable, not chat memory:
   `${CLAUDE_PLUGIN_ROOT}/bin/hold.py hold --task <id> --q "..." [--opts "a|b|c"]`, acted on only after
   `${CLAUDE_PLUGIN_ROOT}/bin/hold.py answer <id> --a "..."`. The plugin's SessionStart hook surfaces open holds
   each session, so a restart never drops a pending gate — reconcile any it reports before new work.

7. **Integrate** only after a passing verdict + a `PASS` gate + an answered hold. `scout` tasks stop at a report.

## Visible orchestration in herdr (when HERDR_ENV=1)

By default the maker and checker run headless (in-process sub-agent + background scripts) — the captain can't
watch them. Inside herdr, run the loop in VISIBLE side-by-side panes. You stay in your pane and drive the
others via the herdr CLI. First check: `${CLAUDE_PLUGIN_ROOT}/bin/herdr-pane.sh check` (if it fails, use the
headless path). Every split uses `--no-focus` so the captain's focus never moves.

- **Maker pane** — a live agent the captain watches work:
  ```
  mk=$(${CLAUDE_PLUGIN_ROOT}/bin/herdr-pane.sh split right)
  herdr agent start sm-maker --kind claude --pane "$mk" -- --model <maker-model>
  herdr agent prompt sm-maker "/loop-task <goal> — implement in <worktree>" --wait --timeout 600000
  ```
- **Checker pane** — the edit-locked checker, run headless IN the pane so it's visible AND capturable, with
  only the lenses the diff needs:
  ```
  ck=$(${CLAUDE_PLUGIN_ROOT}/bin/herdr-pane.sh split down)
  herdr pane run "$ck" '${CLAUDE_PLUGIN_ROOT}/bin/launch-checker.sh --lens redteam/injection --addendum-text "..." -- -p "Review this diff and give your verdict:
  <diff>" ; echo ___SM_DONE_$?'
  herdr pane wait-output "$ck" --regex "___SM_DONE_[0-9]" --timeout 240000   # match the RESOLVED marker, not the command echo
  herdr pane read "$ck" --source recent-unwrapped --lines 200 > /tmp/sm-checker.out
  ${CLAUDE_PLUGIN_ROOT}/bin/verdict.py /tmp/sm-checker.out                    # branch on exit code, as always
  ```
- **Watch + integrate from your pane** — `herdr agent get/read sm-maker`, `herdr pane read "$ck"`; then the
  usual verify-gate + hold. You can't answer another pane's live prompt, so run any gated command yourself
  in the supervisor context (still a separate context, so maker ≠ checker holds).
- **Clean up ONLY the panes you created**: `herdr pane close "$mk"`, `herdr pane close "$ck"`.

Not in herdr (`HERDR_ENV != 1`)? Use the headless path — in-process maker sub-agent + `run-round.sh`-wrapped
checker. Same loop, same guards, just not visible.

## Not for
Trivial one-shot edits, read-only questions, or work with no verifiable result — do those directly.
