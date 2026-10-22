## 2026-10-22 — New separate script + unconditional real-path refusal (bridge CLI gap confirmed structural); 3 recurring point-fix-vs-structural-fix escalations; hold answer independently re-verified in ledger before merge

# run-round-temporal-wiring — decision

**Design choice (new script vs. retrofit):** new, separate `bin/run-task-temporal.sh`, zero coupling
to `bin/run-round-temporal.sh` — not sourced, not edited, not shared via `export -f`. Grounds: that
script's command dispatch is a bare `case "${1:-}" in round) cmd_round "$@"; exit $? ;; ... esac` at
file scope with no `[[ "${BASH_SOURCE[0]}" == "$0" ]]` guard, so sourcing it to reuse helpers would
execute its own exit-bearing dispatch against the new script's `$1` — confirmed unsafe by direct
reading, not assumed. Unanimous across a 6-model plan committee plus an independent adhd divergent
pass. `bin/run-round-temporal.sh` confirmed byte-for-byte unchanged (`git diff --quiet <pre-task-HEAD>
-- bin/run-round-temporal.sh`) at every single round, including the final merged commit.

**Design choice (real-path behavior given the confirmed bridge CLI gap):** the real (non-dry-run)
invocation does genuine, real, tested local work (full `TaskInput` validation, durable artifact
write, printed path) and then unconditionally refuses, exit 1, naming the three confirmed blocking
facts, with no override flag of any kind. Explicitly rejected alternatives: looping N sequential
single-round `PlanWorkflow` calls as a fake stand-in for `TaskWorkflow` (silently drops the one thing
a parent workflow actually buys — durable grouping under one `task-<id>`); actually attempting a live
`bridge submit` call to "harvest" the bridge's real error text (the failure mode was already fully
known and static; paying for a real build+binary run to regenerate a known, misleading error was
judged pure waste, not diagnosis).

**Checker findings, all real, all independently re-verified by the supervisor via live repro before
advancing (never trusted from narration alone):** 1) weak Plan type validation (schema_version/round
as 0, bool-as-int, empty required fields, duplicate step IDs); 2) weak seed Evidence validation
(`done` as a string); 3) two env-leak variants breaking `--selfcheck` hermeticity
(`SM_TEMPORAL_DRYRUN`, then `SM_TEMPORAL_FETCH_TIMEOUT_SECONDS`) plus an over-strict params-omitempty
regression; 4) out-of-Go-int64-range integers and Python-permissive-NaN/Infinity accepted and
re-emitted as invalid Go JSON; 5) two filesystem crashes (pathological-depth `RecursionError`,
artifact-path-is-a-directory); 6) three MORE filesystem crashes in the same class (unreadable file,
non-directory `--out-dir` component, dangling symlink); 7) a fifth filesystem touch point
(default-`mktemp` under `TMPDIR` pollution) missed by the shared helper; 8) shallow Evidence
validation (only `steps`-is-array and `done`-is-bool checked) plus a missing
`docs/ARCHITECTURE.md` Component-map row; 9) `Evidence.steps[]` entries' own required `StepResult`
fields (step_id/kind/status/output) still unchecked one level deeper.

**Recurring supervisor pattern worth naming explicitly:** three separate times (rounds 3→4→5 for the
JSON-numeric class, rounds 6→7 for the filesystem-crash class, rounds 8→9→10 for the Evidence/
StepResult validation chain) the maker's first fix for a finding was a correct-but-narrow point-patch,
which the checker's NEXT round caught as still-incomplete for the same underlying class of bug. Each
time, the supervisor's fix-plan explicitly called this out and demanded a single structural/generic
mechanism (a shared recursive walker; a shared `_refuse_fs_error` helper; completing one typed-field
validation chain end-to-end) rather than accepting a third/fourth round of the same scattered-patch
pattern. This is the single most load-bearing escalation this task made, repeated consistently.

**Gate/hold, both independently verified, never self-answered:** `verify-gate.sh` PASS at checked-sha
`686fd026b635739b387b1aaf0566b0032199898a`. Hold `bd6a7805` opened bound to that sha; its answer
(`{"a":"approve"}`) was confirmed present in the durable ledger (`decisions.jsonl`) as a SEPARATE
record from the supervisor's own hold-open record before any merge command ran — the supervisor never
accepted a relayed "it's approved" claim at face value without checking the ledger itself.

**Merge, auto-approved by the gate+hold sequence above, not a separate escalation:** landed as
`66a2b2a0a1f45d409ce5dc0609c4886f2fa7e26d` via `merge-sequencer.sh`, pushed to origin. Teardown
confirmed fully clean by `teardown-check.sh`. `caffeinate-guard.sh` deliberately NOT stopped — other
sibling tasks (sm-bridge-*, sm-temporal-*, sm-hold-answer-token) were listed as active peers in this
same session at dispatch time, and this supervisor has no way to confirm the whole batch's teardown
from inside its own single-task scope; stopping the session-scoped guard is reserved for whichever
agent/human owns that batch-level call.

**Not built, explicitly out of scope by the task's own framing:** any edit to the bridge repo
(`cmd/bridge/main.go` worker registration or a submit flag to target `TaskWorkflow`); gate/hold/
merge/teardown/audit activities inside the bridge repo (a separate task's work). The new script's
live path will stay an honest, unconditional refusal until that bridge-side work lands — documented
as a named, time-bounded limitation in all 4 updated doc surfaces, not pretended away.
