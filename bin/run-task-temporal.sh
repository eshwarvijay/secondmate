#!/usr/bin/env bash
# run-task-temporal.sh -- assembles + validates a TaskInput JSON payload ({task_id, rounds: []Plan,
# seed_rounds?: []Evidence}) for submitting a WHOLE multi-round task into the Temporal bridge
# prototype's internal/planrun.TaskWorkflow (a child-per-round parent workflow with a deterministic
# task-<id> WorkflowID via StartTask). Sibling to bin/run-round-temporal.sh (which only ever submits
# ONE Plan into PlanWorkflow) -- NOT coupled to it: this script never sources it, never calls it, and
# is never called by it. The only thing borrowed from it is its own dry-run Plan JSON shape, used
# below purely as a validation oracle.
#
#   run-task-temporal.sh task --task-id ID --rounds-file F [--seed-rounds-file F] [--out-dir DIR]
#   run-task-temporal.sh --selfcheck
#
#   --task-id ID        (required; validated against ^[a-z0-9][a-z0-9_-]{0,19}$, the same
#                         charset/length rule bin/run-round-temporal.sh already enforces for its own
#                         --herdr-task-id)
#   --rounds-file F      (required; a JSON array of already-fully-formed Plan objects, one per
#                         round, IN ROUND ORDER -- order is encoded ONLY by array position, there is
#                         no explicit index field. Build each entry the same way
#                         bin/run-round-temporal.sh's own SM_TEMPORAL_DRYRUN=1 path already does
#                         (its "PLAN:" JSON blob) -- this script validates against that exact shape,
#                         it does not re-derive or rebuild it)
#   --seed-rounds-file F (optional; a JSON array of Evidence objects, the same shape `bridge fetch`
#                         already returns under its "evidence" key -- omitted from the assembled
#                         TaskInput entirely when not given or given an empty array)
#   --out-dir DIR        (optional; default: a fresh mktemp -d. Where the real-path artifact file
#                         is written)
#
# Env: SM_TEMPORAL_DRYRUN=1 -- print the assembled TaskInput JSON to stdout and exit 0, instead of
#      writing it to a file and refusing (mirrors bin/run-round-temporal.sh's own convention)
#
# Stdout contract: dry-run stdout is "TASK_INPUT:" + the JSON + "WORKFLOW_ID: task-<id>" -- plain
# labeled text, never a {verdict} envelope shape, never pipeable into bin/verdict.py by habit.
# Real-path stdout is "WROTE: <artifact path>" + "WORKFLOW_ID: task-<id>" + the refusal below.
#
# Exit codes: 0 ok (dry-run only) | 1 refusal (real path, unconditional, every time) |
#             2 usage/validation error
#
# REAL-PATH REFUSAL -- unconditional, no override flag, exit 1, every time, before any subprocess
# that could resemble a bridge build/worker/submit call (there is none in this script at all):
# live submission into internal/planrun.TaskWorkflow is a structural impossibility today, confirmed
# by direct reading of the read-only bridge dependency at /Users/eshwar.vijay/coupa/temporal-local-
# fork/bridge (never modified by this script):
#   1. cmd/bridge/main.go's `worker` subcommand registers ONLY planrun.PlanWorkflow, never
#      TaskWorkflow, via its one w.RegisterWorkflow call.
#   2. cmd/bridge/main.go's `submit` subcommand hardcodes
#      c.ExecuteWorkflow(ctx, opts, planrun.PlanWorkflow, plan) with no flag to target TaskWorkflow.
#   3. internal/planrun is Go-`internal`: nothing outside the bridge module can call StartTask
#      directly either.
# This script writes the validated TaskInput JSON to a durable artifact file and prints its path --
# a ready hand-off for whenever the bridge gains TaskWorkflow CLI/worker wiring (out of scope here)
# -- then refuses. It never loops N bin/run-round-temporal.sh/PlanWorkflow calls as a fake stand-in
# for TaskWorkflow: that would silently drop the one thing a parent workflow actually buys (durable
# grouping of every round under one task-<id> workflow), and would look like it works when it does
# not.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: $0 task --task-id ID --rounds-file F [--seed-rounds-file F] [--out-dir DIR]" >&2
  echo "       $0 --selfcheck" >&2
}

# --- validates + assembles the TaskInput JSON. Exits 2 (via python's own sys.exit) on any shape
# violation, with a message on stderr naming exactly which part of the shape failed. Validates
# rounds[] against the Plan skeleton (schema_version/round/goal/steps[].id|kind|params) that
# bin/run-round-temporal.sh's own dry-run output already produces -- the oracle for this shape is
# that script's real output, exercised directly in --selfcheck below, not reinvented here.
_build_task_json() {  # _build_task_json <task_id> <rounds_file> <seed_rounds_file>
  python3 -c '
import json, sys

task_id, rounds_file, seed_rounds_file = sys.argv[1], sys.argv[2], sys.argv[3]

def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)

try:
    with open(rounds_file) as f:
        rounds = json.load(f)
except Exception as e:
    fail(f"could not parse --rounds-file as JSON: {e}")

if not isinstance(rounds, list) or len(rounds) == 0:
    fail("--rounds-file must be a non-empty JSON array of Plan objects")

for i, p in enumerate(rounds):
    if not isinstance(p, dict):
        fail(f"rounds[{i}] is not a JSON object")
    # bool is a subclass of int in Python -- isinstance(True, int) is True -- so every numeric
    # check below excludes bool explicitly, not just checks isinstance(..., int). schema_version
    # must be the literal int 1: the only value run-round-temporal own oracle Plan JSON (the
    # one real, proven producer of this shape in this repo) ever emits.
    sv = p.get("schema_version")
    if not isinstance(sv, int) or isinstance(sv, bool) or sv != 1:
        fail(f"rounds[{i}].schema_version must be the literal int 1 (got {sv!r})")
    rnd = p.get("round")
    if not isinstance(rnd, int) or isinstance(rnd, bool) or rnd < 1:
        fail(f"rounds[{i}].round must be a non-bool int >= 1 (got {rnd!r})")
    goal = p.get("goal")
    if not isinstance(goal, str) or goal == "":
        fail(f"rounds[{i}].goal must be a non-empty string (got {goal!r})")
    steps = p.get("steps")
    if not isinstance(steps, list) or len(steps) == 0:
        fail(f"rounds[{i}].steps must be a non-empty array")
    seen_ids = set()
    for j, s in enumerate(steps):
        if not isinstance(s, dict):
            fail(f"rounds[{i}].steps[{j}] is not a JSON object")
        sid = s.get("id")
        kind = s.get("kind")
        params = s.get("params")
        if not isinstance(sid, str) or sid == "":
            fail(f"rounds[{i}].steps[{j}].id must be a non-empty string (got {sid!r})")
        if not isinstance(kind, str) or kind == "":
            fail(f"rounds[{i}].steps[{j}].kind must be a non-empty string (got {kind!r})")
        # [CONFIRMED finding 2, checker round 3] the real bridge Step.Params field is
        # map[string]any with a json omitempty tag -- the bridge own TaskWorkflow test uses a step
        # with NO params field at all as a valid Plan. An absent key (s.get returns None) or an
        # explicit JSON null (also None) must be treated as an empty object, not rejected. Only
        # reject params when it is PRESENT and actually the wrong type (a string, array, or number).
        if params is not None and not isinstance(params, dict):
            fail(f"rounds[{i}].steps[{j}].params, when present, must be an object (got {params!r})")
        if sid in seen_ids:
            fail(f"rounds[{i}].steps[{j}].id {sid!r} is a duplicate within this round -- step ids must be unique per round")
        seen_ids.add(sid)

task = {"task_id": task_id, "rounds": rounds}

if seed_rounds_file:
    try:
        with open(seed_rounds_file) as f:
            seed_rounds = json.load(f)
    except Exception as e:
        fail(f"could not parse --seed-rounds-file as JSON: {e}")
    if not isinstance(seed_rounds, list):
        fail("--seed-rounds-file must be a JSON array of Evidence objects")
    for i, e in enumerate(seed_rounds):
        if not isinstance(e, dict):
            fail(f"seed_rounds[{i}] is not a JSON object")
        if not isinstance(e.get("steps"), list):
            fail(f"seed_rounds[{i}].steps must be an array (Evidence shape)")
        done = e.get("done")
        # isinstance(done, bool) correctly excludes str/int/None here (bool is NOT a superclass of
        # int -- isinstance(1, bool) is False) -- a truthy non-bool like "not-a-boolean" must fail.
        if not isinstance(done, bool):
            fail(f"seed_rounds[{i}].done must be a real bool, not {type(done).__name__} (got {done!r}) -- same Evidence shape bridge fetch already returns")
    if seed_rounds:
        task["seed_rounds"] = seed_rounds

print(json.dumps(task, indent=2))
' "$1" "$2" "${3:-}"
}

cmd_task() {
  local task_id="" rounds_file="" seed_rounds_file="" out_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task-id) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; task_id="$2"; shift 2;;
      --rounds-file) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; rounds_file="$2"; shift 2;;
      --seed-rounds-file) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; seed_rounds_file="$2"; shift 2;;
      --out-dir) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; out_dir="$2"; shift 2;;
      *) echo "unknown arg: $1" >&2; return 2;;
    esac
  done

  [ -n "$task_id" ] || { echo "need --task-id ID" >&2; usage; return 2; }
  [[ "$task_id" =~ ^[a-z0-9][a-z0-9_-]{0,19}$ ]] || { echo "invalid --task-id: $task_id (must match ^[a-z0-9][a-z0-9_-]{0,19}\$ -- lowercase alnum/dash/underscore, 1-20 chars, starting with alnum; same rule run-round-temporal.sh's own --herdr-task-id enforces)" >&2; return 2; }
  [ -n "$rounds_file" ] || { echo "need --rounds-file F" >&2; usage; return 2; }
  [ -f "$rounds_file" ] || { echo "rounds-file not found: $rounds_file" >&2; return 2; }
  if [ -n "$seed_rounds_file" ]; then
    [ -f "$seed_rounds_file" ] || { echo "seed-rounds-file not found: $seed_rounds_file" >&2; return 2; }
  fi

  local task_json
  task_json="$(_build_task_json "$task_id" "$rounds_file" "$seed_rounds_file")"

  local workflow_id="task-$task_id"

  if [ "${SM_TEMPORAL_DRYRUN:-}" = 1 ]; then
    echo "TASK_INPUT:"
    echo "$task_json"
    echo "WORKFLOW_ID: $workflow_id"
    return 0
  fi

  out_dir="${out_dir:-$(mktemp -d "${TMPDIR:-/tmp}/sm-temporal-task.XXXXXX")}"
  mkdir -p "$out_dir"
  local artifact="$out_dir/task-input.json"
  echo "$task_json" > "$artifact"

  echo "WROTE: $artifact"
  echo "WORKFLOW_ID: $workflow_id"
  echo "REFUSING: live submission into internal/planrun.TaskWorkflow is not possible today -- this is a structural impossibility, not a risk to accept with a flag, so there is no override. Three confirmed blocking facts (verified by direct reading of the read-only bridge dependency, never touched by this script): (1) cmd/bridge/main.go's 'worker' subcommand registers ONLY planrun.PlanWorkflow, never TaskWorkflow, via its one w.RegisterWorkflow call; (2) its 'submit' subcommand hardcodes c.ExecuteWorkflow(ctx, opts, planrun.PlanWorkflow, plan) with no flag to target TaskWorkflow instead; (3) internal/planrun is Go-internal, so nothing outside the bridge module can call StartTask directly either. The TaskInput JSON above has already been validated and written to the artifact path above as a ready hand-off for whenever the bridge gains TaskWorkflow CLI/worker wiring."
  return 1
}

_selfcheck() {
  local fails=0 rc out

  # (a) ordinary CLI arg validation -- the two cases that have no valid-input ambiguity at all.
  rc=0; "$0" task >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: no --task-id exit $rc (want 2)"; fails=1; }
  rc=0; "$0" task --task-id abc >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: no --rounds-file exit $rc (want 2)"; fails=1; }

  # (g) identical charset/length rule as run-round-temporal.sh's own --herdr-task-id -- literal
  # source match against BOTH files, not just a coincidentally-equal regex typed twice.
  grep -qF '^[a-z0-9][a-z0-9_-]{0,19}$' "$0" || { echo "FAIL: this script's own --task-id regex literal not found in source"; fails=1; }
  grep -qF '^[a-z0-9][a-z0-9_-]{0,19}$' "$SCRIPT_DIR/run-round-temporal.sh" || { echo "FAIL: run-round-temporal.sh's --herdr-task-id regex literal not found (oracle missing)"; fails=1; }

  # --- fixture git repo, used only to drive run-round-temporal.sh's own dry-run (its own --repo
  # precondition) so this suite can harvest REAL oracle Plan JSON from it, never a reimplementation.
  local t; t="$(mktemp -d)"
  git -C "$t" init -q -b main; git -C "$t" config user.email a@a; git -C "$t" config user.name a
  echo seed > "$t/f"; git -C "$t" add -A; git -C "$t" commit -qm seed

  # SM_LOOP_STATE pinned at an always-empty, freshly-made directory for every oracle call: without
  # this, run-round-temporal.sh's own _maker_boilerplate splices in whatever round-state.md happens
  # to already exist on disk (e.g. this very repo's own .secondmate/round-state.md), which can itself
  # contain the literal substring "seed_rounds" in ordinary prose -- confirmed live, this leaked into
  # the oracle's maker_prompt and produced a false FAIL on the (e) seed_rounds-absence check below.
  #
  # Every SM_TEMPORAL_* var run-round-temporal.sh's own header/module-scope reads is ALSO pinned
  # here, not just SM_TEMPORAL_DRYRUN (which must stay "1" -- that's what makes this an oracle dry-
  # run at all). A prior fix only cleared SM_TEMPORAL_DRYRUN and still left this same class of bug
  # open for its siblings: SM_TEMPORAL_FETCH_TIMEOUT_SECONDS is validated at that script's own
  # MODULE SCOPE, unconditionally, before cmd_round's dry-run branch ever runs -- so a non-numeric
  # ambient value (e.g. inherited from a shell that was just debugging the sibling script) made
  # `_oracle_plan` fail with exit 2 regardless of DRYRUN, confirmed live. SM_TEMPORAL_GO_BIN/
  # SM_TEMPORAL_GO_DOWNLOAD_CACHE are read later inside cmd_round and never actually reached before
  # the dry-run branch returns today, but are pinned anyway on the same "don't whack-a-mole one
  # variable at a time" principle the checker named -- this oracle call's behavior must be fully
  # independent of the calling shell's ambient env, not just immune to today's one known trigger.
  # (SM_TEMPORAL_FAKE_BRIDGE_BIN and friends are deliberately excluded: run-round-temporal.sh's own
  # security hardening proves those names are never read at all, by design -- pinning them here
  # would be pinning nothing.)
  local oracle_state_dir; oracle_state_dir="$(mktemp -d)"
  _oracle_plan() {  # _oracle_plan <round> <goal>
    local round="$1" goal="$2" oracle_out
    oracle_out="$(HERDR_ENV="" SM_LOOP_STATE="$oracle_state_dir" SM_TEMPORAL_DRYRUN=1 \
      SM_TEMPORAL_GO_BIN="" SM_TEMPORAL_GO_DOWNLOAD_CACHE="" SM_TEMPORAL_FETCH_TIMEOUT_SECONDS="" \
      "$SCRIPT_DIR/run-round-temporal.sh" round --repo "$t" --checker-goal "$goal" --maker-prompt "do it" --round "$round" 2>/dev/null)" || return 1
    echo "$oracle_out" | python3 -c '
import json, sys
lines = sys.stdin.read().splitlines()
start = lines.index("PLAN:") + 1
end = next(i for i, l in enumerate(lines) if l.startswith("WOULD RUN:"))
print(json.dumps(json.loads("\n".join(lines[start:end]))))
'
  }

  local plan_a plan_b plan_c
  plan_a="$(_oracle_plan 1 "round-A")" || { echo "FAIL: could not generate oracle plan A from run-round-temporal.sh's own dry-run"; fails=1; }
  plan_b="$(_oracle_plan 2 "round-B")" || { echo "FAIL: could not generate oracle plan B from run-round-temporal.sh's own dry-run"; fails=1; }
  plan_c="$(_oracle_plan 3 "round-C")" || { echo "FAIL: could not generate oracle plan C from run-round-temporal.sh's own dry-run"; fails=1; }

  local rounds_file="$t/rounds.json"
  python3 -c '
import json, sys
print(json.dumps([json.loads(sys.argv[1]), json.loads(sys.argv[2]), json.loads(sys.argv[3])]))
' "$plan_a" "$plan_b" "$plan_c" > "$rounds_file"

  # (a)/(g) continued: --task-id charset/length checks, using a VALID --rounds-file +
  # SM_TEMPORAL_DRYRUN=1 (not /nonexistent) so the two outcomes are genuinely distinguishable --
  # validation present -> exit 2 from the charset check; validation missing/bypassed -> exit 0 from
  # the dry-run branch succeeding. Reusing /nonexistent here would make exit 2 ambiguous: it could
  # just as easily come from the unrelated missing-rounds-file check, the exact coincidental-exit-
  # code trap run-round-temporal.sh's own selfcheck documents hitting more than once. Confirmed live
  # via mutation: with /nonexistent, neutering the charset check still passed this suite.
  rc=0; SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "Upper" --rounds-file "$rounds_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: uppercase --task-id exit $rc (want 2)"; fails=1; }
  rc=0; SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "-bad" --rounds-file "$rounds_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: leading-dash --task-id exit $rc (want 2)"; fails=1; }
  rc=0; SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "123456789012345678901" --rounds-file "$rounds_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: 21-char --task-id exit $rc (want 2)"; fails=1; }
  rc=0; SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "" --rounds-file "$rounds_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: empty --task-id exit $rc (want 2)"; fails=1; }

  # (b)/(c) overall TaskInput shape + each rounds[] entry passing the real oracle Plan shape
  out="$(SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "selfcheck-task" --rounds-file "$rounds_file" 2>&1)" \
    || { echo "FAIL: dryrun task errored against real oracle plans: $out"; fails=1; }
  echo "$out" | grep -q '"task_id": "selfcheck-task"' || { echo "FAIL: TaskInput missing task_id"; fails=1; }
  echo "$out" | grep -qF '"goal": "round-A"' || { echo "FAIL: TaskInput rounds[0] missing expected goal from the real oracle plan"; fails=1; }

  # (d) rounds[] order survives the assembly pipeline byte-for-byte under a shuffled input -- round
  # sequence is encoded ONLY by array position, no explicit index field.
  local shuffled_rounds_file="$t/rounds-shuffled.json"
  python3 -c '
import json, sys
print(json.dumps([json.loads(sys.argv[1]), json.loads(sys.argv[2]), json.loads(sys.argv[3])]))
' "$plan_c" "$plan_a" "$plan_b" > "$shuffled_rounds_file"
  out="$(SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "selfcheck-task" --rounds-file "$shuffled_rounds_file" 2>&1)" \
    || { echo "FAIL: dryrun task errored on shuffled rounds"; fails=1; }
  echo "$out" | python3 -c '
import json, sys
lines = sys.stdin.read().splitlines()
start = lines.index("TASK_INPUT:") + 1
end = next(i for i, l in enumerate(lines) if l.startswith("WORKFLOW_ID:"))
task = json.loads("\n".join(lines[start:end]))
goals = [r["goal"] for r in task["rounds"]]
assert goals == ["round-C", "round-A", "round-B"], f"rounds[] order not preserved byte-for-byte: {goals}"
' || { echo "FAIL [CRITICAL]: rounds[] array order was not preserved byte-for-byte under a shuffled input"; fails=1; }

  # (e) seed_rounds omitted when absent/empty, present + Evidence-shaped when given. Matches the
  # literal JSON KEY form (quoted, with its colon), never a bare substring: a maker prompt embedded
  # inside a rounds[] entry can legitimately contain the word "seed_rounds" in ordinary prose (e.g.
  # this very selfcheck's own round-state.md handoff describes this flag) without that meaning the
  # TaskInput actually carries a seed_rounds KEY -- confirmed live, a bare substring grep false-
  # failed on exactly that.
  out="$(SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "selfcheck-task" --rounds-file "$rounds_file" 2>&1)"
  echo "$out" | grep -q '"seed_rounds"' && { echo "FAIL: seed_rounds must be omitted entirely when --seed-rounds-file is not given"; fails=1; }

  local empty_seed_file="$t/seed-empty.json"
  echo '[]' > "$empty_seed_file"
  out="$(SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "selfcheck-task" --rounds-file "$rounds_file" --seed-rounds-file "$empty_seed_file" 2>&1)"
  echo "$out" | grep -q '"seed_rounds"' && { echo "FAIL: seed_rounds must be omitted entirely when --seed-rounds-file is an empty array"; fails=1; }

  local seed_file="$t/seed.json"
  cat > "$seed_file" <<'SEED_EOF'
[{"schema_version":1,"round":0,"goal":"seed evidence","steps":[{"step_id":"step-maker","kind":"maker","status":"ok","output":"seed maker output","diff":""},{"step_id":"step-checker","kind":"checker","status":"ok","output":"seed checker output"}],"done":true}]
SEED_EOF
  out="$(SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "selfcheck-task" --rounds-file "$rounds_file" --seed-rounds-file "$seed_file" 2>&1)" \
    || { echo "FAIL: dryrun task errored with a valid --seed-rounds-file"; fails=1; }
  echo "$out" | grep -qF '"goal": "seed evidence"' || { echo "FAIL: seed_rounds content missing from assembled TaskInput"; fails=1; }

  local malformed_seed_file="$t/seed-bad.json"
  echo '[{"not_evidence_shaped": true}]' > "$malformed_seed_file"
  rc=0; "$0" task --task-id "selfcheck-task" --rounds-file "$rounds_file" --seed-rounds-file "$malformed_seed_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: malformed seed_rounds entry exit $rc (want 2)"; fails=1; }

  # (f) task_id -> "task-<id>" WorkflowID derivation
  out="$(SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "mytask123" --rounds-file "$rounds_file" 2>&1)"
  echo "$out" | grep -qF 'WORKFLOW_ID: task-mytask123' || { echo "FAIL: task_id -> task-<id> WorkflowID derivation not asserted correctly"; fails=1; }

  # malformed/empty rounds[] must exit 2, never silently assemble a bad TaskInput
  local bad_rounds_file="$t/rounds-bad.json"
  echo '[{"not_a_plan": true}]' > "$bad_rounds_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$bad_rounds_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: malformed rounds[] entry exit $rc (want 2)"; fails=1; }

  local empty_rounds_file="$t/rounds-empty.json"
  echo '[]' > "$empty_rounds_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$empty_rounds_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: empty rounds[] array exit $rc (want 2)"; fails=1; }

  # (h) the real (non-dry-run) refusal: exit 1, three-fact message, artifact actually written, and
  # (structurally) zero code path in this script could ever invoke a real bridge binary.
  # SM_TEMPORAL_DRYRUN is explicitly PINNED EMPTY here, not just HERDR_ENV -- without this, a
  # calling shell that already has SM_TEMPORAL_DRYRUN=1 exported (e.g. an operator who was just
  # working with the sibling script) silently converts this sub-invocation into a dry-run call,
  # which exits 0 instead of 1 and never exercises the refusal path at all. Confirmed live: running
  # `SM_TEMPORAL_DRYRUN=1 bin/run-task-temporal.sh --selfcheck` used to fail THIS check for exactly
  # that reason, even though the script under test was correct -- --selfcheck's own result must not
  # depend on what the calling shell happens to have exported.
  rc=0
  out="$(HERDR_ENV="" SM_TEMPORAL_DRYRUN="" "$0" task --task-id "selfcheck-task" --rounds-file "$rounds_file" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: real-path invocation exit $rc (want 1)"; fails=1; }
  echo "$out" | grep -q 'REFUSING:' || { echo "FAIL: refusal message missing"; fails=1; }
  echo "$out" | grep -q 'registers ONLY planrun.PlanWorkflow' || { echo "FAIL: refusal missing fact 1 (worker never registers TaskWorkflow)"; fails=1; }
  echo "$out" | grep -q 'hardcodes c.ExecuteWorkflow' || { echo "FAIL: refusal missing fact 2 (submit hardcodes PlanWorkflow)"; fails=1; }
  echo "$out" | grep -q 'internal/planrun is Go-internal' || { echo "FAIL: refusal missing fact 3 (internal/planrun unreachable externally)"; fails=1; }
  echo "$out" | grep -q '^WROTE:' || { echo "FAIL: artifact path missing from real-path output"; fails=1; }
  local artifact_path; artifact_path="$(echo "$out" | grep '^WROTE:' | sed 's/^WROTE: //')"
  [ -f "$artifact_path" ] || { echo "FAIL: artifact file was not actually written at the reported path"; fails=1; }
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$artifact_path" >/dev/null 2>&1 \
    || { echo "FAIL: artifact file is not valid JSON"; fails=1; }
  # Searches only cmd_task's own function body (never this selfcheck's own source, which
  # necessarily contains these same substrings as the text of the check itself -- a whole-file
  # search would trivially self-match and falsely "pass" a reintroduced invocation too).
  sed -n '/^cmd_task() {$/,/^_selfcheck() {$/p' "$0" | grep -qE '"\$.*bridge"|bridge submit|bridge worker|bridge fetch' \
    && { echo "FAIL [CRITICAL]: cmd_task contains a literal bridge-binary invocation -- the refusal must be unconditional, with zero code path that could ever call a real bridge binary"; fails=1; }

  # [CONFIRMED finding 1, checker round 1] a rounds[] entry that satisfies bare Python types but
  # violates the real Plan contract (empty goal, empty/duplicate step ids/kinds, schema_version 0)
  # must be rejected, exit 2 -- not silently accepted and emitted into TASK_INPUT.
  local weak_plan_file="$t/rounds-weak-plan.json"
  echo '[{"schema_version":0,"round":0,"goal":"","steps":[{"id":"","kind":"","params":{}},{"id":"","kind":"","params":{}}]}]' > "$weak_plan_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$weak_plan_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1]: schema_version:0/round:0/empty-goal/empty-dup-step-ids rounds[] entry exit $rc (want 2)"; fails=1; }

  # [CONFIRMED finding 1, checker round 1] Python's bool-is-an-int-subclass trap: schema_version
  # and round given as JSON `true` must NOT pass as valid ints.
  local bool_plan_file="$t/rounds-bool.json"
  echo '[{"schema_version":true,"round":true,"goal":"g","steps":[{"id":"s1","kind":"maker","params":{}}]}]' > "$bool_plan_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$bool_plan_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1]: schema_version/round given as JSON true (bool-is-int trap) exit $rc (want 2)"; fails=1; }

  # Isolated single-field violations -- each fixture below is otherwise fully valid, so disabling
  # any ONE of these checks (confirmed live by mutation-testing each in turn) is caught by exactly
  # that fixture and no other. weak_plan_file/bool_plan_file above each break multiple fields at
  # once, which a mutation test proved is not enough on its own: neutering the schema_version check
  # alone left the SAME overall exit code (2) on both those fixtures, because their OTHER broken
  # fields (round, goal, step ids) independently also trip exit 2 -- fully masking that one
  # specific check from ever being exercised in isolation.
  local valid_base='"round":1,"goal":"g","steps":[{"id":"s1","kind":"maker","params":{}}]'
  local iso_schema_file="$t/rounds-iso-schema.json"
  echo "[{\"schema_version\":2,${valid_base}}]" > "$iso_schema_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$iso_schema_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1]: schema_version:2 (otherwise fully valid) exit $rc (want 2)"; fails=1; }

  local iso_round_file="$t/rounds-iso-round.json"
  echo '[{"schema_version":1,"round":0,"goal":"g","steps":[{"id":"s1","kind":"maker","params":{}}]}]' > "$iso_round_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$iso_round_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1]: round:0 (otherwise fully valid) exit $rc (want 2)"; fails=1; }

  local iso_goal_file="$t/rounds-iso-goal.json"
  echo '[{"schema_version":1,"round":1,"goal":"","steps":[{"id":"s1","kind":"maker","params":{}}]}]' > "$iso_goal_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$iso_goal_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1]: empty goal (otherwise fully valid) exit $rc (want 2)"; fails=1; }

  local iso_stepid_file="$t/rounds-iso-stepid.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","steps":[{"id":"","kind":"maker","params":{}}]}]' > "$iso_stepid_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$iso_stepid_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1]: empty step id (otherwise fully valid) exit $rc (want 2)"; fails=1; }

  local iso_stepkind_file="$t/rounds-iso-stepkind.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","steps":[{"id":"s1","kind":"","params":{}}]}]' > "$iso_stepkind_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$iso_stepkind_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1]: empty step kind (otherwise fully valid) exit $rc (want 2)"; fails=1; }

  # duplicate non-empty step ids within one round must also be rejected (order-position-only
  # uniqueness, same spirit as the (d) order-preservation guarantee above).
  local dup_id_file="$t/rounds-dup-id.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","steps":[{"id":"dup","kind":"maker","params":{}},{"id":"dup","kind":"checker","params":{}}]}]' > "$dup_id_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$dup_id_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1]: duplicate step ids within one round exit $rc (want 2)"; fails=1; }

  # [CONFIRMED finding 2, checker round 3] a step with NO params field at all is a bridge-VALID
  # Plan shape (Step.Params is `map[string]any `json:"params,omitempty"``, and the bridge's own
  # TaskWorkflow test uses exactly this no-params shape) -- must assemble successfully, exit 0.
  local no_params_file="$t/rounds-no-params.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","steps":[{"id":"s1","kind":"noop"}]}]' > "$no_params_file"
  rc=0; SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "x" --rounds-file "$no_params_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL [CONFIRMED finding 2, round 3]: step with no params field at all exit $rc (want 0 -- this is a bridge-valid Plan shape, omitempty)"; fails=1; }

  # explicit JSON null for params must be treated the same as absent -- still valid, exit 0.
  local null_params_file="$t/rounds-null-params.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","steps":[{"id":"s1","kind":"noop","params":null}]}]' > "$null_params_file"
  rc=0; SM_TEMPORAL_DRYRUN=1 "$0" task --task-id "x" --rounds-file "$null_params_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL [CONFIRMED finding 2, round 3]: step with params:null exit $rc (want 0, same as absent)"; fails=1; }

  # but params, when PRESENT, must still be rejected if it is the wrong type (e.g. a string) --
  # the fix only relaxes the absent/null case, it must not have gone too far the other way.
  local wrong_type_params_file="$t/rounds-wrong-type-params.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","steps":[{"id":"s1","kind":"noop","params":"not-an-object"}]}]' > "$wrong_type_params_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$wrong_type_params_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 2, round 3]: step with params given as a string exit $rc (want 2 -- present-but-wrong-type must still be rejected)"; fails=1; }

  # [CONFIRMED finding 2, checker round 1] a seed_rounds[] entry with done given as a non-bool
  # (a Python str, not a real bool) must be rejected, exit 2 -- not echoed straight into TASK_INPUT.
  local bad_done_seed_file="$t/seed-bad-done.json"
  echo '[{"steps":[],"done":"not-a-boolean"}]' > "$bad_done_seed_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$rounds_file" --seed-rounds-file "$bad_done_seed_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 2]: seed_rounds[].done as a non-bool string exit $rc (want 2)"; fails=1; }

  # [CONFIRMED finding 3, checker round 1] --selfcheck's own result must not depend on whatever
  # SM_TEMPORAL_DRYRUN the calling shell already has exported -- the real-path refusal sub-test
  # above used to silently turn into a dry-run call under an inherited SM_TEMPORAL_DRYRUN=1,
  # masking the very thing it was meant to prove. Re-runs the WHOLE suite once, polluted with
  # SM_TEMPORAL_DRYRUN=1 ambient, and asserts it still exits 0. _SM_SELFCHECK_NESTED guards against
  # unbounded recursion: this check only ever fires at the top level, never inside its own child.
  if [ "${_SM_SELFCHECK_NESTED:-}" != 1 ]; then
    rc=0
    SM_TEMPORAL_DRYRUN=1 _SM_SELFCHECK_NESTED=1 "$0" --selfcheck >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { echo "FAIL [CONFIRMED finding 3]: --selfcheck run under an inherited SM_TEMPORAL_DRYRUN=1 exited $rc (want 0) -- its own sub-tests must be hermetic against the calling shell's ambient env"; fails=1; }
  fi

  # [CONFIRMED finding 1, checker round 3] the SM_TEMPORAL_DRYRUN-only fix above was too narrow --
  # _oracle_plan's own call into run-round-temporal.sh also inherited SIBLING SM_TEMPORAL_* vars
  # from the calling shell (SM_TEMPORAL_FETCH_TIMEOUT_SECONDS is validated at that script's own
  # module scope, unconditionally, so a non-numeric ambient value broke the oracle call regardless
  # of DRYRUN). This exports SEVERAL of them at once (not just the one variable the checker named),
  # to prove the fix closes the whole class rather than being hammered back into a single-variable
  # whack-a-mole fix. Same recursion guard as the check above, reused rather than duplicated.
  if [ "${_SM_SELFCHECK_NESTED:-}" != 1 ]; then
    rc=0
    SM_TEMPORAL_FETCH_TIMEOUT_SECONDS="not-a-number" SM_TEMPORAL_GO_BIN="/nonexistent-go-xyz-$$" \
      SM_TEMPORAL_GO_DOWNLOAD_CACHE="/nonexistent-cache-xyz-$$" _SM_SELFCHECK_NESTED=1 \
      "$0" --selfcheck >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { echo "FAIL [CONFIRMED finding 1, round 3]: --selfcheck run under several polluted ambient SM_TEMPORAL_* vars (FETCH_TIMEOUT_SECONDS/GO_BIN/GO_DOWNLOAD_CACHE) exited $rc (want 0) -- the oracle call must pin every SM_TEMPORAL_* var run-round-temporal.sh reads, not just SM_TEMPORAL_DRYRUN"; fails=1; }
  fi

  rm -rf "$t" "$oracle_state_dir"

  # (i) bin/run-round-temporal.sh must remain byte-for-byte unchanged from its committed HEAD -- this
  # task's own success condition, checked structurally against git itself, not a guess.
  if git -C "$SCRIPT_DIR/.." rev-parse HEAD >/dev/null 2>&1; then
    git -C "$SCRIPT_DIR/.." diff --quiet HEAD -- bin/run-round-temporal.sh \
      || { echo "FAIL [CRITICAL]: bin/run-round-temporal.sh differs from its committed HEAD -- must remain byte-for-byte unchanged"; fails=1; }
  fi

  [ "$fails" = 0 ] && echo ok
  return "$fails"
}

case "${1:-}" in
  --selfcheck) _selfcheck; exit $? ;;
  task) shift; cmd_task "$@"; exit $? ;;
  *) usage; exit 2 ;;
esac
