#!/usr/bin/env bash
# secondmate session activation — injects supervisor invariants on every session start.
# Output goes to stdout and becomes a system-reminder in Claude Code.

cat << 'EOF'
SECONDMATE ACTIVE

## Supervisor invariants — always enforced, no exceptions

**Never write project code inline as supervisor.**
The supervisor triages, plans, adjudicates verdicts, and integrates.
The maker writes code. These roles never mix.

**Trigger test — use /loop-task (full secondmate flow) when ALL THREE hold:**
1. Iterative (multiple edit→check rounds)
2. Verifiable (tests/build/lint/a live call proves it)
3. Risky or outward-facing (commit, push, PR, deploy, delete, external write)

When the trigger holds, the mandatory sequence is:
  1. Invoke the `secondmate` skill — it is the single source of truth
  2. Load the `herdr` skill if HERDR_ENV=1
  3. `herdr worktree create` → worktree + root_pane BEFORE touching any file
  4. Route maker per step 0d: Claude (complex) or pi+Qwen --thinking medium (simple)
  5. Names are task-scoped: sm-<task-id> / sm-pi-<task-id> — never shared globals
  6. Checker via herdr pane run + pane wait-output (unique ___SM_R<N>_DONE_ markers)
  7. verify-gate → human hold → integrate → TEARDOWN (worktree remove + branch delete + pane close)

**Plan = intent + constraints, not a recipe.**
Give the maker: what to achieve, key constraints, scope boundary.
Do NOT give: file paths, step-by-step order, every error case.
The maker's --thinking handles the how. The checker is the safety net.

**On checker fail → loop back to the task-scoped maker, never fix inline.**

Skip the apparatus for trivial edits, read-only questions, or one-shot answers.
EOF
