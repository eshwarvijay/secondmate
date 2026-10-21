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
import json, math, sys

task_id, rounds_file, seed_rounds_file = sys.argv[1], sys.argv[2], sys.argv[3]

def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)

# [CONFIRMED finding 2, checker round 4] Go encoding/json flatly rejects NaN/Infinity/-Infinity as
# invalid JSON ("invalid character N looking for beginning of value"); Python json module
# permissively accepts and even round-trips these non-standard tokens through json.dumps. A params
# value (or anything else, anywhere in the document) containing one of these would validate here
# and then be unusable -- not even parseable -- by the real bridge. parse_constant intercepts these
# tokens STRUCTURALLY, at parse time, at every nesting depth in one pass -- not a recursive walk
# over the result that could miss a level. Shared by BOTH loaders below (rounds-file and
# seed-rounds-file), the single fix point the checker asked for, so a third sibling "Python accepts
# more than Go" gap does not need its own scattered fix later.
def _reject_nonstandard_json_constant(token):
    raise ValueError(f"non-standard JSON constant {token!r} is not valid JSON -- Go encoding/json rejects it")

# [CONFIRMED finding 1, checker round 4] the real bridge Plan.Round/Plan.SchemaVersion fields are
# Go int -- 64-bit signed on every realistic deployment target -- so a JSON integer outside
# [-2**63, 2**63-1] (Python int is arbitrary-precision and happily parses it) would validate here
# and then be rejected by the real bridge own encoding/json unmarshal ("cannot unmarshal number ...
# into Go struct field"). Shared helper, used for both fields below, so schema_version stays
# protected even though it is pinned to exactly 1 today -- if that pin is ever loosened, the bound
# is already there.
GO_INT64_MIN = -(2 ** 63)
GO_INT64_MAX = 2 ** 63 - 1

def is_go_int(value):
    # bool is a subclass of int in Python -- isinstance(True, int) is True -- excluded explicitly.
    return isinstance(value, int) and not isinstance(value, bool) and GO_INT64_MIN <= value <= GO_INT64_MAX

# [CONFIRMED finding 1+2, checker round 5] round 4 only point-fixed two specific spots (schema_
# version/round for oversized ints; params for the NaN/Infinity CONSTANT TOKENS) -- the SAME class
# of bug still escapes through any OTHER field: an arbitrarily-nested params value
# (params.x, params.n.deep, ...), a top-level criteria field, a future field, or anything inside
# seed_rounds, since none of those were individually enumerated. This ONE generic walker replaces
# point-fixing a growing list of named fields: it recurses over an ARBITRARY parsed JSON value --
# dict, list, or scalar, any nesting depth -- and fails on anything the real bridge own Go
# encoding/json could never actually unmarshal: a non-finite float (NaN/Infinity/-Infinity --
# reachable not only via the non-standard constant TOKENS parse_constant below already catches, but
# also via an ordinary JSON float LITERAL like 1e999, which Python own float() silently overflows
# to inf with no error at all), or an int outside the Go int64 range. bool is deliberately exempted
# -- isinstance(True, int) is True in Python, but flagging a bool as an oversized int would
# conflate two unrelated concerns; that distinction is already handled correctly elsewhere
# (is_go_int above), not this walker job. Folded into strict_json_load itself (below) so BOTH
# loaders -- rounds-file and seed-rounds-file -- get it from the one call site, automatically, over
# their ENTIRE parsed content, not as a second scattered check someone has to remember to add.
def _check_go_compatible_value(value, path):
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            fail(f"{path} is a non-finite number ({value!r}) -- Go encoding/json cannot represent NaN/Infinity/-Infinity")
        return
    if isinstance(value, int):
        if not (GO_INT64_MIN <= value <= GO_INT64_MAX):
            fail(f"{path} is an integer outside the Go int64 range (got {value!r})")
        return
    if isinstance(value, dict):
        for k, v in value.items():
            _check_go_compatible_value(v, f"{path}.{k}")
        return
    if isinstance(value, list):
        for idx, v in enumerate(value):
            _check_go_compatible_value(v, f"{path}[{idx}]")
        return

def strict_json_load(path, what):
    try:
        with open(path) as f:
            data = json.load(f, parse_constant=_reject_nonstandard_json_constant)
    except ValueError as e:
        fail(f"could not parse {what} as strict, Go-compatible JSON: {e}")
    _check_go_compatible_value(data, what)
    return data

# [CONFIRMED finding 1, checker round 6] a pathologically deep input (e.g. 1000 nested JSON
# arrays) crashes json.load itself, or _check_go_compatible_value own recursion, or the final
# json.dumps re-serialization, with an uncaught RecursionError and a raw traceback -- and the SAME
# depth with an ordinary, otherwise-valid value at the bottom crashes identically, even though the
# real Go encoding/json would accept it fine (a false-positive rejection risk, not just an ugly
# crash). Fixed pragmatically, NOT by trying to replicate Go own depth tolerance byte for byte (a
# rabbit hole not worth chasing) -- the entire pipeline below is wrapped in ONE outer function,
# with ONE try/except RecursionError boundary around the single call site, converting ANY recursion
# overflow anywhere in parse/walk/serialize into a clean, named, exit-2 usage error. This is a
# deliberate, documented, proportionate limitation (same "accepted, documented tradeoff" posture as
# the NAMED LIMITATIONS this repo own run-round-temporal.sh header already uses): extremely-deep-
# but-otherwise-valid input is rejected too under this limit, on purpose, rather than chasing a more
# clever depth-aware parser.
def _run():
    rounds = strict_json_load(rounds_file, "--rounds-file")

    if not isinstance(rounds, list) or len(rounds) == 0:
        fail("--rounds-file must be a non-empty JSON array of Plan objects")

    for i, p in enumerate(rounds):
        if not isinstance(p, dict):
            fail(f"rounds[{i}] is not a JSON object")
        sv = p.get("schema_version")
        if not is_go_int(sv):
            fail(f"rounds[{i}].schema_version must be an int within the Go int64 range (got {sv!r})")
        if sv != 1:
            fail(f"rounds[{i}].schema_version must be the literal int 1 (got {sv!r})")
        rnd = p.get("round")
        if not is_go_int(rnd):
            fail(f"rounds[{i}].round must be an int within the Go int64 range (got {rnd!r})")
        if rnd < 1:
            fail(f"rounds[{i}].round must be >= 1 (got {rnd!r})")
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
            # map[string]any with a json omitempty tag -- the bridge own TaskWorkflow test uses a
            # step with NO params field at all as a valid Plan. An absent key (s.get returns None)
            # or an explicit JSON null (also None) must be treated as an empty object, not
            # rejected. Only reject params when it is PRESENT and actually the wrong type.
            if params is not None and not isinstance(params, dict):
                fail(f"rounds[{i}].steps[{j}].params, when present, must be an object (got {params!r})")
            if sid in seen_ids:
                fail(f"rounds[{i}].steps[{j}].id {sid!r} is a duplicate within this round -- step ids must be unique per round")
            seen_ids.add(sid)

    task = {"task_id": task_id, "rounds": rounds}

    if seed_rounds_file:
        seed_rounds = strict_json_load(seed_rounds_file, "--seed-rounds-file")
        if not isinstance(seed_rounds, list):
            fail("--seed-rounds-file must be a JSON array of Evidence objects")
        for i, e in enumerate(seed_rounds):
            if not isinstance(e, dict):
                fail(f"seed_rounds[{i}] is not a JSON object")
            if not isinstance(e.get("steps"), list):
                fail(f"seed_rounds[{i}].steps must be an array (Evidence shape)")
            done = e.get("done")
            # isinstance(done, bool) correctly excludes str/int/None (bool is NOT a superclass of
            # int -- isinstance(1, bool) is False) -- a truthy non-bool like "not-a-boolean" fails.
            if not isinstance(done, bool):
                fail(f"seed_rounds[{i}].done must be a real bool, not {type(done).__name__} (got {done!r}) -- same Evidence shape bridge fetch already returns")
        if seed_rounds:
            task["seed_rounds"] = seed_rounds

    print(json.dumps(task, indent=2))

try:
    _run()
except RecursionError:
    fail("JSON nesting too deep to validate safely (Python recursion limit exceeded while parsing, walking, or re-serializing the input) -- a deliberate, named limitation of this validator, not a crash: reduce the nesting depth of --rounds-file/--seed-rounds-file content. This rejects some extremely-deep-but-otherwise-valid input too; that is an accepted, documented tradeoff, not something this script tries to solve more cleverly by replicating the real bridge own depth tolerance.")
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
  # Same bug class as the artifact-path collision guard just below, one level up: a pre-existing
  # --out-dir that is itself a plain file (not a directory) crashes `mkdir -p` with a raw shell
  # "File exists" error under set -e -- found via this round's own further adversarial testing,
  # directly adjacent to the checker's artifact-collision finding, so fixed here too rather than
  # left as a sibling crash.
  if [ -e "$out_dir" ] && [ ! -d "$out_dir" ]; then
    echo "refusing: --out-dir already exists and is not a directory: $out_dir -- cannot write the TaskInput artifact there" >&2
    return 2
  fi
  mkdir -p "$out_dir"
  local artifact="$out_dir/task-input.json"
  # [CONFIRMED finding 2, checker round 6] a bare `echo ... > "$artifact"` crashes with a raw
  # shell "Is a directory" error (exit 1, under set -e) when something already sits at this exact
  # path and is not a plain file -- with NEITHER the mandated WROTE: line NOR the mandated
  # REFUSING: three-fact report ever printed. A caller (accidentally, or an attacker deliberately)
  # pre-creating a directory at this exact path would silently suppress the refusal report. Checked
  # BEFORE attempting the write, so this is always a clean, named, exit-2 usage error -- never an
  # uncaught crash -- on this path.
  if [ -e "$artifact" ] && [ ! -f "$artifact" ]; then
    echo "refusing: artifact path already exists and is not a plain file: $artifact (e.g. a pre-existing directory at this exact path) -- cannot write the TaskInput artifact there" >&2
    return 2
  fi
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

  # [CONFIRMED finding 1, checker round 4] the real bridge Plan.Round field is a Go int (64-bit
  # signed on every realistic target) -- a round value one past Go's int64 max must be rejected,
  # not silently accepted and emitted into an artifact the bridge could not actually unmarshal.
  local oversized_round_file="$t/rounds-oversized-round.json"
  echo '[{"schema_version":1,"round":9223372036854775808,"goal":"g","steps":[{"id":"s1","kind":"maker","params":{}}]}]' > "$oversized_round_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$oversized_round_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1, round 4]: round one past Go int64 max (2^63) exit $rc (want 2)"; fails=1; }

  # the negative side of the same bound must also be rejected (one past Go int64 min).
  local undersized_round_file="$t/rounds-undersized-round.json"
  echo '[{"schema_version":1,"round":-9223372036854775809,"goal":"g","steps":[{"id":"s1","kind":"maker","params":{}}]}]' > "$undersized_round_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$undersized_round_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1, round 4]: round one past Go int64 min (-2^63-1) exit $rc (want 2)"; fails=1; }

  # the exact Go int64 boundary values themselves ARE otherwise-valid magnitudes (schema_version
  # pins round to >=1 anyway, but the BOUND check itself must not off-by-one reject a value that is
  # genuinely still in range) -- schema_version given at the exact max must still only fail on the
  # separate "!= 1" check, never on the range check, proving the range comparison is inclusive.
  local max_schema_version_file="$t/rounds-max-schema-version.json"
  echo '[{"schema_version":9223372036854775807,"round":1,"goal":"g","steps":[{"id":"s1","kind":"maker","params":{}}]}]' > "$max_schema_version_file"
  rc=0; out="$("$0" task --task-id "x" --rounds-file "$max_schema_version_file" 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: schema_version at exact Go int64 max exit $rc (want 2)"; fails=1; }
  echo "$out" | grep -q 'within the Go int64 range' && { echo "FAIL [CONFIRMED finding 1, round 4]: schema_version at the exact Go int64 max boundary was wrongly rejected by the RANGE check (off-by-one) instead of the separate != 1 check"; fails=1; }

  # [CONFIRMED finding 2, checker round 4] NaN/Infinity/-Infinity are non-standard JSON extensions
  # Python permissively accepts (and round-trips); Go encoding/json flatly rejects them as invalid
  # JSON -- the validated artifact would not even be parseable by the bridge. Three probe points:
  # inside params (where the checker's exact repro landed), deeply nested two levels further down
  # (proving the structural parse-time fix, not a recursive walk that could miss a level), and in a
  # field this validator does not otherwise even inspect (criteria) -- proving the fix covers the
  # WHOLE document, not just the fields this script happens to validate.
  local nan_in_params_file="$t/rounds-nan-params.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","steps":[{"id":"s1","kind":"maker","params":{"x":NaN}}]}]' > "$nan_in_params_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$nan_in_params_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 2, round 4]: NaN inside params exit $rc (want 2)"; fails=1; }

  local inf_nested_file="$t/rounds-inf-nested.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","steps":[{"id":"s1","kind":"maker","params":{"nested":{"deep":[1,2,{"x":Infinity}]}}}]}]' > "$inf_nested_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$inf_nested_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 2, round 4]: Infinity two levels deep inside params exit $rc (want 2)"; fails=1; }

  local neg_inf_criteria_file="$t/rounds-neginf-criteria.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","criteria":-Infinity,"steps":[{"id":"s1","kind":"maker","params":{}}]}]' > "$neg_inf_criteria_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$neg_inf_criteria_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 2, round 4]: -Infinity in criteria (a field this validator never inspects by name) exit $rc (want 2 -- the fix must cover the whole document, not just validated fields)"; fails=1; }

  # the same NaN rejection must apply to --seed-rounds-file too -- same shared strict-load helper,
  # not a second, possibly-forgotten copy of the fix.
  local nan_seed_file="$t/seed-nan.json"
  echo '[{"steps":[],"done":true,"cost_usd":NaN}]' > "$nan_seed_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$rounds_file" --seed-rounds-file "$nan_seed_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 2, round 4]: NaN inside --seed-rounds-file exit $rc (want 2)"; fails=1; }

  # [CONFIRMED finding 1+2, checker round 5] round 4's fixes only covered two NAMED fields
  # (schema_version/round for oversized ints, params for the NaN/Infinity constant tokens). The
  # generic walker (_check_go_compatible_value, folded into strict_json_load) must catch the SAME
  # class anywhere else in the document -- an arbitrarily-nested params value, a field this
  # validator never names (criteria), and seed_rounds. These are the checker's own exact repros,
  # plus two adversarial cases of our own in a spot the checker did not mention (nested inside
  # seed_rounds.steps) to prove the walker is genuinely generic, not another enumerated list.
  local nested_oversized_int_file="$t/rounds-nested-oversized-int.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","steps":[{"id":"s1","kind":"maker","params":{"x":9223372036854775808}}]}]' > "$nested_oversized_int_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$nested_oversized_int_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1, round 5]: oversized int nested in params.x exit $rc (want 2)"; fails=1; }

  local deeply_nested_oversized_int_file="$t/rounds-deeply-nested-oversized-int.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","steps":[{"id":"s1","kind":"maker","params":{"n":{"deep":9223372036854775808}}}]}]' > "$deeply_nested_oversized_int_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$deeply_nested_oversized_int_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1, round 5]: oversized int two levels deep in params.n.deep exit $rc (want 2)"; fails=1; }

  local oversized_int_seed_file="$t/seed-oversized-int.json"
  echo '[{"steps":[],"done":true,"x":9223372036854775808}]' > "$oversized_int_seed_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$rounds_file" --seed-rounds-file "$oversized_int_seed_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1, round 5]: oversized int in a seed_rounds field this validator never names exit $rc (want 2)"; fails=1; }

  local scientific_inf_criteria_file="$t/rounds-1e999-criteria.json"
  echo '[{"schema_version":1,"round":1,"goal":"g","criteria":1e999,"steps":[{"id":"s1","kind":"maker","params":{}}]}]' > "$scientific_inf_criteria_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$scientific_inf_criteria_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 2, round 5]: 1e999 (a float LITERAL overflowing to inf, not the NaN/Infinity constant TOKEN) in criteria exit $rc (want 2)"; fails=1; }

  # adversarial, not named by the checker: nested inside seed_rounds[].steps[], several levels
  # down, inside an array -- proving the walker is a genuine generic recursion, not a list of
  # specifically-anticipated field names.
  local adversarial_seed_nested_int_file="$t/seed-adversarial-nested-int.json"
  echo '[{"steps":[{"step_id":"s1","nested":{"arr":[1,2,{"x":9223372036854775808}]}}],"done":true}]' > "$adversarial_seed_nested_int_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$rounds_file" --seed-rounds-file "$adversarial_seed_nested_int_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1, round 5, adversarial]: oversized int nested inside seed_rounds[].steps[].nested.arr[] exit $rc (want 2)"; fails=1; }

  local adversarial_seed_nested_inf_file="$t/seed-adversarial-nested-inf.json"
  echo '[{"steps":[{"step_id":"s1","cost_breakdown":{"items":[{"amount":1e999}]}}],"done":true}]' > "$adversarial_seed_nested_inf_file"
  rc=0; "$0" task --task-id "x" --rounds-file "$rounds_file" --seed-rounds-file "$adversarial_seed_nested_inf_file" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 2, round 5, adversarial]: 1e999 nested inside seed_rounds[].steps[].cost_breakdown.items[] exit $rc (want 2)"; fails=1; }

  # [CONFIRMED finding 1, checker round 6] a pathologically deep rounds-file (well past Python own
  # default recursion limit) must fail cleanly, exit 2, with a named message -- never an uncaught
  # RecursionError/raw traceback. Built via plain string concatenation (never json.dump, which
  # itself recurses once per level and would crash building this very fixture at this depth).
  local deep_rounds_file="$t/rounds-deeply-nested.json"
  python3 -c '
depth = 1000
nested = "[" * depth + "42" + "]" * depth
doc = ("[{\"schema_version\":1,\"round\":1,\"goal\":\"g\",\"steps\":[{\"id\":\"s1\",\"kind\":\"maker\","
       "\"params\":{\"a\":" + nested + "}}]}]")
with open("'"$deep_rounds_file"'", "w") as fh:
    fh.write(doc)
'
rc=0
out="$("$0" task --task-id "x" --rounds-file "$deep_rounds_file" 2>&1)" || rc=$?
[ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 1, round 6]: pathologically deep (1000-level) rounds-file exit $rc (want 2, not a crash)"; fails=1; }
echo "$out" | grep -qi 'traceback' && { echo "FAIL [CONFIRMED finding 1, round 6]: pathologically deep rounds-file leaked a raw Python traceback instead of a clean message"; fails=1; }
echo "$out" | grep -qi 'too deep' || { echo "FAIL [CONFIRMED finding 1, round 6]: pathologically deep rounds-file did not produce the expected clean too-deep message"; fails=1; }

  # [CONFIRMED finding 2, checker round 6] if the real-path artifact's target path already exists
  # AS A DIRECTORY, the write must refuse cleanly, exit 2, with NEITHER a misleading WROTE: line
  # NOR a misleading REFUSING: report -- never an uncaught shell "Is a directory" crash that could
  # let a caller (or an attacker pre-creating that exact path) silently suppress the refusal report.
  local collision_out_dir="$t/collision-out"
  mkdir -p "$collision_out_dir/task-input.json"
  rc=0
  out="$(HERDR_ENV="" SM_TEMPORAL_DRYRUN="" "$0" task --task-id "x" --rounds-file "$rounds_file" --out-dir "$collision_out_dir" 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [CONFIRMED finding 2, round 6]: artifact-path-is-a-directory collision exit $rc (want 2, not a crash)"; fails=1; }
  echo "$out" | grep -qi 'traceback\|is a directory' && { echo "FAIL [CONFIRMED finding 2, round 6]: artifact-path collision leaked a raw crash/shell error instead of a clean message"; fails=1; }
  echo "$out" | grep -q '^WROTE:' && { echo "FAIL [CONFIRMED finding 2, round 6]: artifact-path collision still printed a WROTE: line despite the write never happening"; fails=1; }
  echo "$out" | grep -q '^REFUSING:' && { echo "FAIL [CONFIRMED finding 2, round 6]: artifact-path collision still printed the REFUSING: report despite the write never happening"; fails=1; }
  echo "$out" | grep -qi 'already exists' || { echo "FAIL [CONFIRMED finding 2, round 6]: artifact-path collision did not name the collision clearly"; fails=1; }
  [ -d "$collision_out_dir/task-input.json" ] || { echo "FAIL: pre-existing collision directory was unexpectedly removed/altered by this check"; fails=1; }

  # [CONFIRMED finding 2, checker round 6] the ordinary (non-collision) real-path write must still
  # work exactly as before -- the new guard must not be a false positive on a normal, fresh out-dir.
  local normal_out_dir="$t/normal-out"
  rc=0
  out="$(HERDR_ENV="" SM_TEMPORAL_DRYRUN="" "$0" task --task-id "x" --rounds-file "$rounds_file" --out-dir "$normal_out_dir" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: ordinary real-path write with a fresh --out-dir exit $rc (want 1, the normal refusal)"; fails=1; }
  [ -f "$normal_out_dir/task-input.json" ] || { echo "FAIL: ordinary real-path write did not actually write the artifact (new guard false-positived)"; fails=1; }

  # [found via this round's OWN further adversarial testing, same bug class as finding 2] --out-dir
  # itself (one level up from the artifact file inside it) already existing as a plain file must
  # also refuse cleanly, exit 2, never an uncaught `mkdir -p` "File exists" crash.
  local out_dir_as_file="$t/out-dir-as-file"
  echo "not a directory" > "$out_dir_as_file"
  rc=0
  out="$(HERDR_ENV="" SM_TEMPORAL_DRYRUN="" "$0" task --task-id "x" --rounds-file "$rounds_file" --out-dir "$out_dir_as_file" 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL [found via further testing, same class as finding 2]: --out-dir pre-existing as a plain file exit $rc (want 2, not a crash)"; fails=1; }
  echo "$out" | grep -qi 'traceback\|file exists' && { echo "FAIL [found via further testing, same class as finding 2]: --out-dir-as-a-file leaked a raw mkdir/shell crash instead of a clean message"; fails=1; }
  echo "$out" | grep -q '^WROTE:' && { echo "FAIL [found via further testing, same class as finding 2]: --out-dir-as-a-file still printed a WROTE: line despite the write never happening"; fails=1; }
  [ "$(cat "$out_dir_as_file")" = "not a directory" ] || { echo "FAIL: pre-existing --out-dir file content was unexpectedly altered by this check"; fails=1; }

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
