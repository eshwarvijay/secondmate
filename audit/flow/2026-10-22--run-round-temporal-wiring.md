## 2026-10-22 — run-task-temporal.sh: new whole-task TaskWorkflow validate-and-refuse CLI, 10 rounds (1 build + 9 fix), unanimous plan-committee design, zero regression to run-round-temporal.sh

# run-round-temporal-wiring — flow

**Trigger:** dispatched sub-agent-supervisor task. Goal: give secondmate a way to submit a WHOLE
multi-round task into the Temporal bridge prototype's new `internal/planrun.TaskWorkflow`, instead of
`bin/run-round-temporal.sh`'s existing one-round-only `PlanWorkflow` submission via `bridge submit`.

**Plan committee (unconditional, pre-triage):** ran `adhd` (5 cognitive frames) + `plan-committee.sh`
(6 models: deepseek-r1, glm5, kimi-k3, mistral-large3, qwen3-80b, qwen3-coder) against a task
description that already included the supervisor's own direct-source-reading finding (the blocking
fact below). All 6 planners plus the adhd synthesis converged unanimously on: (a) a new, separate
script rather than retrofitting `run-round-temporal.sh` (that script's bare, unguarded dispatch makes
sourcing it for shared helpers unsafe, and its own identity/docs are "one round only"), and (b) the
real (non-dry-run) path should do genuine local validation/artifact-write work, then unconditionally
refuse — never attempt a live bridge submission, since doing so today would be actively wrong (the
bridge's `submit` would misinterpret a `TaskInput` payload as a malformed `Plan`).

**Confirmed blocking fact (direct source reading, not a guess):** `cmd/bridge/main.go`'s `worker`
subcommand registers ONLY `planrun.PlanWorkflow` (never `TaskWorkflow`); `submit` hardcodes
`c.ExecuteWorkflow(ctx, opts, planrun.PlanWorkflow, plan)` with no flag to target `TaskWorkflow`;
`internal/planrun` is Go-`internal`, unreachable from outside the bridge module. Live `TaskWorkflow`
submission is a structural impossibility today without editing `cmd/bridge/main.go` — explicitly
forbidden for this task (2 sibling tasks were concurrently active in that repo; it was never touched).

**Maker:** Claude, routed directly per the dispatcher's explicit instruction (not a routing judgment
call this time). Ran under `ponytail --ultra` for every round per explicit instruction.

**Rounds:** 1 initial build + 9 fix rounds, all against the same cross-model pi checker
(`global.openai.gpt-5.6-terra`), run visibly in a herdr pane (`herdr-pane.sh split`), with
`qa/test-reality` + `qa/coverage` lenses loaded throughout. Every maker round independently
re-verified by the supervisor itself (not just trusting self-reports) before advancing: ran both
scripts' `--selfcheck`, re-ran the checker's own exact repro commands, confirmed
`bin/run-round-temporal.sh` byte-identical to its pre-task HEAD at every single round.

Round-by-round verdicts, all FAIL except the last:
1. FAIL — weak Plan validation (schema_version:0/round:0/empty fields/dup step IDs/bool-as-int all
   wrongly accepted).
2. FAIL — weak seed Evidence validation (`done` accepted as a string); non-hermetic `--selfcheck`
   (leaked ambient `SM_TEMPORAL_DRYRUN`).
3. FAIL — a narrower sibling env-leak (`SM_TEMPORAL_FETCH_TIMEOUT_SECONDS`, not caught by round 2's
   narrow fix); an over-strict params-omitempty regression from round 1's own fix rejecting a
   bridge-valid no-params step.
4. FAIL — out-of-Go-int64-range integer accepted; NaN/Infinity accepted via Python's permissive json
   module (round-4's own fix was itself rejected by the checker next round for being more point-fixes,
   not a generic walker).
5. FAIL — the generic walker (round 5) was structurally correct for every realistic case, but a
   pathologically deep (1000-level) structure crashed with `RecursionError`, and a pre-existing
   directory at the artifact path crashed with a raw "Is a directory" error.
6. FAIL — round 6 fixed those 2 named crashes, but the checker found 3 MORE filesystem-error crashes
   in the same class (unreadable file, non-directory `--out-dir` component, dangling symlink) —
   round 6's named-scenario guards were rejected as insufficiently general.
7. FAIL — round 7's shared `_refuse_fs_error` helper closed 4 of 5 filesystem touch points; the 5th
   (default `mktemp -d` scratch dir under `TMPDIR=/dev/null`) was missed.
8. FAIL — round 8 closed the 5th touch point; checker then found Evidence/seed_rounds validation was
   still shallow (only checked `steps` is an array and `done` is a bool, not the rest of the typed
   Evidence contract), plus a missing `docs/ARCHITECTURE.md` Component-map row.
9. FAIL — round 9 deep-validated Evidence's top-level fields and added the doc row; checker found the
   last gap one level deeper: each `steps[]` entry's own required `StepResult` fields (step_id/kind/
   status/output) were still unchecked.
10. **PASS, zero findings.** Round 10 closed the `StepResult` field validation; full final regression
    sweep across all 10 rounds' invariants came back clean.

**Operational note:** two round-9/round-10 checker-invocation scripts I (the supervisor) wrote myself
had a real bash quoting bug — a multi-line double-quoted shell string got a premature closing `"` at
the end of its `SPEC:` line, splitting `HAMMER:`/`LIVE:` text out as bare unquoted tokens and causing
the checker invocation itself to fail with a bash syntax error before ever running. Caught via
`bash -n`, fixed with a targeted `Edit`, re-verified syntactically clean before re-running. No impact
on the maker's own work — only delayed two checker-round dispatches by one correction cycle each.

**Verify-gate:** PASS at checked-sha `686fd026b635739b387b1aaf0566b0032199898a`
(`verify-gate.sh --worktree <wt> --base main --checked-sha <sha>`).

**Hold:** opened `bd6a7805` bound to that sha; durable ledger confirms a genuine human answer
`{"a":"approve"}` recorded separately from the supervisor's own hold-open record (never self-answered).

**Merge:** `merge-sequencer.sh` merged `sm/run-round-temporal-wiring` → `main` as
`66a2b2a0a1f45d409ce5dc0609c4886f2fa7e26d`, pushed to origin.

**Teardown:** checker pane closed, worktree removed, branch deleted, claim released
(`claim-ledger.py release`), `teardown-check.sh` reports fully clean (worktree/branch/herdr/claim all
clean). `caffeinate-guard.sh` deliberately left running — other sibling tasks were active in this
session at dispatch time and this supervisor cannot confirm the whole batch is torn down; stopping it
is reserved for whoever owns that batch-level decision.
