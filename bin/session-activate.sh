#!/usr/bin/env bash
# secondmate session activation — injects supervisor invariants on every session start.
# Output goes to stdout and becomes a system-reminder in Claude Code.

if [ "${1:-}" = "--selfcheck" ]; then
  # Exercises the REAL output of this exact script (a real subprocess invocation, not a reimplemented
  # copy of its text) and asserts on what it actually prints -- so this would fail if the heredoc below
  # ever drifted out of sync with the current fan-out contract (N=10 cap, two triggers, consolidated
  # batch hold) it's supposed to describe.
  out="$("$0")"
  fails=0
  echo "$out" | grep -q "SECONDMATE ACTIVE" || { echo "FAIL: missing the SECONDMATE ACTIVE banner"; fails=1; }
  echo "$out" | grep -q "Never write project code inline as supervisor." || { echo "FAIL: missing the never-write-inline-as-supervisor invariant"; fails=1; }
  echo "$out" | grep -qi "hard-capped at 10 concurrent" || { echo "FAIL: missing the N=10 concurrent-batch cap wording"; fails=1; }
  echo "$out" | grep -q "NEVER run the maker/checker loop yourself" || { echo "FAIL: missing the dispatch-is-the-only-path wording"; fails=1; }
  echo "$out" | grep -qi "solo dispatch" || { echo "FAIL: missing the solo-dispatch wording"; fails=1; }
  echo "$out" | grep -qi "batch dispatch" || { echo "FAIL: missing the batch-dispatch wording"; fails=1; }
  echo "$out" | grep -qi "consolidated batch hold" || { echo "FAIL: missing the consolidated-batch-hold wording"; fails=1; }
  echo "$out" | grep -q "hard-capped at 2" && { echo "FAIL: stale N=2 wording still present"; fails=1; }
  echo "$out" | grep -qi "opt-in and only on an explicit human ask" && { echo "FAIL: stale opt-in-delegation wording still present"; fails=1; }
  echo "$out" | grep -qi "Headless / not in herdr" || { echo "FAIL: missing the headless/not-in-herdr spawn path"; fails=1; }
  echo "$out" | grep -q "new-worktree.sh" || { echo "FAIL: missing new-worktree.sh as the non-herdr spawn command"; fails=1; }
  echo "$out" | grep -qi "In herdr (HERDR_ENV=1)" || { echo "FAIL: missing the in-herdr spawn path"; fails=1; }
  echo "$out" | grep -q "herdr worktree create" || { echo "FAIL: missing herdr worktree create as the in-herdr spawn command"; fails=1; }
  echo "$out" | grep -qi "never self-answered" || { echo "FAIL: missing the never-self-answered-hold wording"; fails=1; }
  echo "$out" | grep -qi "self-reported task-tracking checklist" || { echo "FAIL: missing the task-tracking checklist seeding wording"; fails=1; }
  echo "$out" | grep -qi "narrows to: recognize the trigger, dispatch" || { echo "FAIL: missing the top-level supervisor's narrowed-job framing"; fails=1; }
  [ "$fails" = 0 ] && echo ok
  exit "$fails"
fi

cat << 'EOF'
SECONDMATE ACTIVE

## Supervisor invariants — always enforced, no exceptions

**Never write project code inline as supervisor.**
The supervisor triages, plans, adjudicates verdicts, and integrates.
The maker writes code. These roles never mix.

**Trigger test — dispatch (full secondmate flow) when ALL THREE hold:**
1. Iterative (multiple edit→check rounds)
2. Verifiable (tests/build/lint/a live call proves it)
3. Risky or outward-facing (commit, push, PR, deploy, delete, external write)

When the trigger holds, you (the top-level supervisor) NEVER run the maker/checker loop yourself — you
dispatch a FRESH sub-agent-supervisor instead: **solo dispatch** for one task, **batch dispatch**
(hard-capped at 10 concurrent, not tunable) for several genuinely independent tasks at once. The
dispatched sub-supervisor runs the mandatory sequence inside its own context:
  0. Seed a self-reported task-tracking checklist (TodoWrite / Task* set / plain fallback) mirroring SOP steps, update items as you progress, so a silently-dropped step shows up as pending
  1. Invoke the `secondmate` skill — it is the single source of truth
  2. Load the `herdr` skill if HERDR_ENV=1
  3. Spawn BEFORE touching any file — **In herdr (HERDR_ENV=1):** `herdr worktree create` → worktree + root_pane. **Headless / not in herdr:** `new-worktree.sh` instead (never the primary checkout)
  4. Route maker per step 0d: Claude (complex) or pi+Qwen --thinking medium (simple)
  5. Names are task-scoped: sm-<task-id> / sm-pi-<task-id> — never shared globals
  6. Checker via herdr pane run + pane wait-output (unique ___SM_R<N>_DONE_ markers) — **when HERDR_ENV=1, headless checker invocation is prohibited, no exceptions** — any checker invocation carrying more than one shell token/command must be written to a script file on disk first and invoked as `herdr pane run <pane> bash <script-path>`, never as an inline multi-command string (the argv-to-PTY-line reconstruction doesn't preserve quoting, causing it to silently run in the wrong cwd and produce false refusals)
  7. verify-gate → its OWN human hold (never self-answered) → integrate → TEARDOWN (worktree remove + branch delete + pane close)

Your own job, as the top-level supervisor, narrows to: recognize the trigger, dispatch, watch for
progress/staleness signals, parse the sub-supervisor's terminal tag via `bin/dispatch-report.py`, relay
stuck/hold situations to the human verbatim, and otherwise stay free for the human's next input.

**Plan = intent + constraints, not a recipe.**
Give the maker: what to achieve, key constraints, scope boundary.
Do NOT give: file paths, step-by-step order, every error case.
The maker's --thinking handles the how. The checker is the safety net.

**On checker fail → loop back to the task-scoped maker, never fix inline.**

**Dispatch is the standard path once the trigger fires, not a special case** — invoke the `secondmate`
skill for exact mechanics, never improvise it. A solo dispatch's sub-supervisor still owns its own hold
and its own merge; a batch dispatch's sub-supervisors each stop at their own verify-gate PASS and the
dispatcher opens ONE consolidated batch hold covering the whole batch instead of one hold per task.

Skip the apparatus for trivial edits, read-only questions, or one-shot answers.
EOF
