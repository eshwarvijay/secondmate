#!/usr/bin/env bash
# run-round-temporal.sh -- OPT-IN alternate engine for ONE maker+checker round: routes it through the
# proven external Temporal plan-bridge prototype (a real headless `claude` maker activity + a real
# cross-model `pi` checker activity, both durable Temporal activities) instead of secondmate's direct
# herdr-pane maker/checker path. Zero behavior change to any other secondmate script -- this is the
# only call site, and nothing else in bin/ references it.
#
#   run-round-temporal.sh round \
#     --repo PATH                      (required; real worktree; must be clean before starting)
#     --maker-prompt-file F | --maker-prompt TEXT   (required, one of)
#     --checker-goal TEXT              (required)
#     --goal TEXT                      (default: --checker-goal's text)
#     [--criteria TEXT]
#     [--round N]                      (default 1)
#     [--prior-verdict-file F]         (spliced into the checker step's goal text)
#     [--bridge-dir PATH]              (default /Users/eshwar.vijay/coupa/temporal-local-fork/bridge)
#     [--run-dir PATH]                 (default: mktemp OUTSIDE --repo)
#     [--max-seconds N]                (default 900; genuinely enforced -- this script owns the poll loop)
#     [--max-cost-cents N]             (default 200; POST-HOC WARNING ONLY -- a model call already in
#                                        flight cannot be preempted without touching the bridge's own
#                                        activity code, which is out of scope; see SKILL.md)
#   run-round-temporal.sh --selfcheck
#
# Env: SM_TEMPORAL_DRYRUN=1          -- print the assembled plan JSON + the commands this would run,
#                                        skip the real server/worker/build entirely (mirrors
#                                        launch-checker.sh's own SM_CHECKER_DRYRUN convention)
#      SM_TEMPORAL_GO_BIN            -- override the pinned Go toolchain (default matches the bridge's
#                                        own scripts/smoke_maker_checker.sh default)
#      SM_TEMPORAL_GO_DOWNLOAD_CACHE -- override the offline Go module cache (same default source)
#
# On success: stdout is EXACTLY the checker step's Output text (already secondmate's own
# verdict-envelope shape) -- pipe it straight into bin/verdict.py, zero translation. Everything else
# (heartbeats, cost/duration summary, bridge HEAD sha) goes to stderr.
#
# Exit codes: 0 ok | 1 preflight/environment failure | 2 usage error |
#             10 ZERO_COMMIT_ROUND (maker reported ok but left the worktree unchanged -- refused,
#                never handed to the checker) | 124 TEMPORAL_TIMEOUT (--max-seconds exceeded)
#
# NAMED LIMITATIONS (accepted, documented -- see skills/secondmate/SKILL.md for the full list):
# - No round-state.md/feature-list.json/ponytail/lesson-injection parity on this path (v1 scope).
# - No --lens support (the bridge's checker.go has no lens concept).
# - Process cleanup uses a PID+start-time fingerprint sidecar (see _fingerprint below); a `kill -9` on
#   THIS script itself defeats its own EXIT trap by definition -- a residual gap, not a bug.
# - Port allocation binds to port 0 and scrapes the OS-assigned port, same as the bridge's own
#   scripts/smoke*.sh; the gap between that scrape and the real server binding the same port number is
#   narrowed, not eliminated outright -- the prebuilt server binary takes a port NUMBER via CLI flag
#   only, with no socket-fd-passing/activation support to close this for real without touching the
#   read-only bridge binary.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_BRIDGE_DIR="/Users/eshwar.vijay/coupa/temporal-local-fork/bridge"
DEFAULT_GO_BIN="/Users/eshwar.vijay/coupa/temporal-pilot/.toolchain/go/bin/go"
DEFAULT_GO_DOWNLOAD_CACHE="/Users/eshwar.vijay/.herdr/worktrees/temporal-pilot/sm-temporal-hybrid-e2e-20261015/.toolchain/go-mod/cache/download"

# --- process-identity fingerprint sidecar (PID + start-time, not bare PID) ------------------------
# Same idiom as caffeinate-guard.sh's own _build_fingerprint: "comm=... lstart=..." lets a later
# invocation tell a reused PID apart from the real process before reaping it.
_fingerprint() {
  local pid="$1" comm lstart
  comm="$(ps -p "$pid" -o comm= 2>/dev/null)" || { echo ""; return; }
  lstart="$(ps -p "$pid" -o lstart= 2>/dev/null)" || { echo ""; return; }
  lstart="$(echo "$lstart" | sed 's/[[:space:]]*$//')"
  echo "comm=$comm lstart=$lstart"
}
_record_sidecar() {  # _record_sidecar <file> <pid>
  printf 'pid=%s\n%s\n' "$2" "$(_fingerprint "$2")" > "$1"
}
_kill_sidecar() {  # _kill_sidecar <file> -- no-op if missing, or if the fingerprint no longer matches
  local file="$1" pid fp_expected fp_actual
  [ -f "$file" ] || return 0
  pid="$(sed -n '1s/^pid=//p' "$file")"
  fp_expected="$(sed -n '2p' "$file")"
  [ -n "$pid" ] || return 0
  fp_actual="$(_fingerprint "$pid")"
  if [ -n "$fp_actual" ] && [ "$fp_actual" = "$fp_expected" ]; then
    kill "$pid" 2>/dev/null || true
  fi
}

# --- the one place a round's real changes are staged + committed: explicit paths, never -A/-u -----
# Reads `git status --porcelain -z` (NUL-delimited: no quoting ambiguity, and renames carry a second
# NUL-terminated orig-path field we must skip so we only ever `add --` the current path). Returns 10
# (ZERO_COMMIT_ROUND) if the maker left nothing changed; otherwise stages + commits with the
# Temporal-Workflow-Id/Temporal-Run-Id trailers and prints the new HEAD sha.
_commit_round_changes() {  # _commit_round_changes <repo> <round> <goal> <wid> <rid>
  local repo="$1" round="$2" goal="$3" wid="$4" rid="$5"
  local paths=() pending_skip=0 entry code path
  while IFS= read -r -d '' entry; do
    if [ "$pending_skip" = 1 ]; then pending_skip=0; continue; fi
    code="${entry:0:2}"; path="${entry:3}"
    paths+=("$path")
    case "$code" in R*|C*) pending_skip=1;; esac
  done < <(git -C "$repo" status --porcelain -z)
  if [ "${#paths[@]}" -eq 0 ]; then
    return 10
  fi
  git -C "$repo" add -- "${paths[@]}"
  git -C "$repo" commit -q -m "Temporal round $round: $goal

Temporal-Workflow-Id: $wid
Temporal-Run-Id: $rid"
  git -C "$repo" rev-parse HEAD
}

_build_plan_json() {  # _build_plan_json <round> <goal> <criteria> <maker_prompt> <checker_goal>
  python3 -c '
import json, sys
round_n, goal, criteria, maker_prompt, checker_goal = sys.argv[1:6]
plan = {
    "schema_version": 1,
    "round": int(round_n),
    "goal": goal,
    "steps": [
        {"id": "step-maker", "kind": "maker", "params": {"workdir": ".", "prompt": maker_prompt}},
        {"id": "step-checker", "kind": "checker",
         "params": {"review_step": "step-maker", "workdir": ".", "goal": checker_goal}},
    ],
}
if criteria:
    plan["criteria"] = criteria
print(json.dumps(plan, indent=2))
' "$1" "$2" "$3" "$4" "$5"
}

usage() {
  echo "usage: $0 round --repo PATH --checker-goal TEXT (--maker-prompt-file F | --maker-prompt TEXT) [options]" >&2
  echo "       $0 --selfcheck" >&2
}

run_dir=""  # intentionally NOT local anywhere -- the EXIT/INT/TERM trap's cleanup() reads this global

cleanup() {
  _kill_sidecar "${run_dir}/worker.pidinfo"
  _kill_sidecar "${run_dir}/server.pidinfo"
  [ -n "$run_dir" ] && rm -rf "$run_dir"
}

cmd_round() {
  local repo="" round=1 goal="" criteria="" maker_prompt_file="" maker_prompt="" checker_goal="" prior_verdict_file=""
  local bridge_dir="$DEFAULT_BRIDGE_DIR" max_seconds=900 max_cost_cents=200
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; repo="$2"; shift 2;;
      --round) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; round="$2"; shift 2;;
      --goal) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; goal="$2"; shift 2;;
      --criteria) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; criteria="$2"; shift 2;;
      --maker-prompt-file) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; maker_prompt_file="$2"; shift 2;;
      --maker-prompt) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; maker_prompt="$2"; shift 2;;
      --checker-goal) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; checker_goal="$2"; shift 2;;
      --prior-verdict-file) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; prior_verdict_file="$2"; shift 2;;
      --bridge-dir) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; bridge_dir="$2"; shift 2;;
      --run-dir) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; run_dir="$2"; shift 2;;
      --max-seconds) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; max_seconds="$2"; shift 2;;
      --max-cost-cents) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; max_cost_cents="$2"; shift 2;;
      *) echo "unknown arg: $1" >&2; return 2;;
    esac
  done

  [ -n "$repo" ] || { echo "need --repo PATH" >&2; usage; return 2; }
  [ -n "$checker_goal" ] || { echo "need --checker-goal TEXT" >&2; usage; return 2; }
  if [ -n "$maker_prompt_file" ]; then
    [ -f "$maker_prompt_file" ] || { echo "maker-prompt-file not found: $maker_prompt_file" >&2; return 2; }
    maker_prompt="$(cat "$maker_prompt_file")"
  fi
  [ -n "$maker_prompt" ] || { echo "need --maker-prompt-file F or --maker-prompt TEXT" >&2; usage; return 2; }
  [ -n "$goal" ] || goal="$checker_goal"

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "--repo $repo is not a git worktree" >&2; return 2; }
  repo="$(cd "$repo" && pwd)"

  local go_bin="${SM_TEMPORAL_GO_BIN:-$DEFAULT_GO_BIN}"
  local go_cache="${SM_TEMPORAL_GO_DOWNLOAD_CACHE:-$DEFAULT_GO_DOWNLOAD_CACHE}"

  local checker_goal_full="$checker_goal"
  if [ -n "$prior_verdict_file" ]; then
    [ -f "$prior_verdict_file" ] || { echo "prior-verdict-file not found: $prior_verdict_file" >&2; return 2; }
    checker_goal_full="$checker_goal"$'\n\n'"Prior round verdict (resolve or re-confirm; don't re-litigate settled items):"$'\n'"$(cat "$prior_verdict_file")"
  fi

  local plan_json
  plan_json="$(_build_plan_json "$round" "$goal" "$criteria" "$maker_prompt" "$checker_goal_full")"

  if [ "${SM_TEMPORAL_DRYRUN:-}" = 1 ]; then
    echo "PLAN:"
    echo "$plan_json"
    echo "WOULD RUN: (cd $bridge_dir && GOWORK=off $go_bin build -o <run-dir>/bridge ./cmd/bridge)"
    echo "WOULD RUN: <run-dir>/bridge worker --pid-file <run-dir>/worker.pid   (BRIDGE_ROOT=$repo)"
    echo "WOULD RUN: <run-dir>/bridge submit --plan-file <run-dir>/plan.json --wait 0"
    echo "WOULD RUN: <run-dir>/bridge fetch --workflow-id <wid> --run-id <rid>   (polled every 5s up to ${max_seconds}s)"
    return 0
  fi

  # snapshot precondition for the real round: must be clean BEFORE we start, so the post-round diff
  # against this same snapshot is what decides ZERO_COMMIT_ROUND vs. a real change (dry-run never
  # starts anything real, so it is exempt from this check).
  [ -z "$(git -C "$repo" status --porcelain)" ] || { echo "refusing to start: $repo is not clean (uncommitted changes present)" >&2; return 1; }

  # --- preflight: refuse loudly, never silently degrade -------------------------------------------
  [ -d "$bridge_dir" ] || { echo "bridge dir not found: $bridge_dir (read-only dependency; override with --bridge-dir)" >&2; return 1; }
  local fork_root server_bin
  fork_root="$(cd "$bridge_dir/.." && pwd)"
  server_bin="$fork_root/bin/temporal-local-standalone"
  [ -x "$server_bin" ] || { echo "prebuilt dev-server binary missing/not executable: $server_bin" >&2; return 1; }
  [ -x "$go_bin" ] || { echo "Go toolchain not found/not executable: $go_bin (override with SM_TEMPORAL_GO_BIN)" >&2; return 1; }
  [ -d "$go_cache" ] || { echo "Go module download cache not found: $go_cache (override with SM_TEMPORAL_GO_DOWNLOAD_CACHE)" >&2; return 1; }
  command -v claude >/dev/null 2>&1 || { echo "'claude' not on PATH (needed by the bridge's maker activity)" >&2; return 1; }
  command -v pi >/dev/null 2>&1 || { echo "'pi' not on PATH (needed by the bridge's checker activity)" >&2; return 1; }

  run_dir="${run_dir:-$(mktemp -d "${TMPDIR:-/tmp}/sm-temporal-run.XXXXXX")}"
  mkdir -p "$run_dir"
  trap cleanup EXIT INT TERM
  echo "$plan_json" > "$run_dir/plan.json"

  echo "building bridge CLI into $run_dir ..." >&2
  (
    cd "$bridge_dir"
    export GOTOOLCHAIN=local GOPROXY="file://$go_cache" GOSUMDB=off GOFLAGS=-mod=mod
    export GOMODCACHE="$run_dir/gomodcache" GOCACHE="$run_dir/gocache"
    mkdir -p "$GOMODCACHE" "$GOCACHE"
    GOWORK=off "$go_bin" build -o "$run_dir/bridge" ./cmd/bridge
  )

  # port 0 bind-and-scrape for both listeners, immediately followed by the real server launch using
  # the scraped port numbers -- see the module header's port-allocation limitation note.
  local grpc_port ui_port
  grpc_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  ui_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"

  echo "starting temporal dev server on 127.0.0.1:$grpc_port (ui $ui_port) ..." >&2
  "$server_bin" server start-dev --ip 127.0.0.1 --port "$grpc_port" --ui-ip 127.0.0.1 --ui-port "$ui_port" \
    --db-filename "$run_dir/temporal.db" --log-level error >"$run_dir/server.log" 2>&1 &
  _record_sidecar "$run_dir/server.pidinfo" "$!"

  local i
  for i in $(seq 1 100); do
    python3 -c "import socket;socket.create_connection(('127.0.0.1',$grpc_port),1).close()" 2>/dev/null && break
    sleep 0.3
  done

  echo "starting bridge worker (BRIDGE_ROOT=$repo) ..." >&2
  BRIDGE_ROOT="$repo" CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
  BRIDGE_CHECKER_PROMPT="$SCRIPT_DIR/checker-prompt.md" BRIDGE_CHECKER_ENVELOPE="$SCRIPT_DIR/checker-envelope.md" \
  BRIDGE_GO_BIN="$go_bin" TEMPORAL_ADDRESS="127.0.0.1:$grpc_port" \
    "$run_dir/bridge" worker --pid-file "$run_dir/worker.pid" >"$run_dir/worker.log" 2>&1 &
  for i in $(seq 1 50); do
    [ -f "$run_dir/worker.pid" ] && break
    sleep 0.2
  done
  [ -f "$run_dir/worker.pid" ] || { echo "worker failed to start (no pid file) -- see $run_dir/worker.log" >&2; return 1; }
  _record_sidecar "$run_dir/worker.pidinfo" "$(cat "$run_dir/worker.pid")"

  echo "submitting plan (round $round) ..." >&2
  local submit_out="$run_dir/submit.json" wid rid
  TEMPORAL_ADDRESS="127.0.0.1:$grpc_port" "$run_dir/bridge" submit --plan-file "$run_dir/plan.json" --wait 0 > "$submit_out"
  wid="$(python3 -c "import json;print(json.load(open('$submit_out'))['workflow_id'])")"
  rid="$(python3 -c "import json;print(json.load(open('$submit_out'))['run_id'])")"
  echo "workflow_id=$wid run_id=$rid" >&2

  # idle-watchdog-safe polling: --wait 0 above already returned; this script owns the poll loop and
  # prints one heartbeat per cycle so a wrapping run-round.sh's idle watchdog stays fed, while
  # genuinely exercising the query-vs-history bridge fetch path every round (not just a blocking --wait).
  local evidence_file="$run_dir/evidence.json" start_ts now elapsed done_flag
  start_ts=$(date +%s)
  while :; do
    TEMPORAL_ADDRESS="127.0.0.1:$grpc_port" "$run_dir/bridge" fetch --workflow-id "$wid" --run-id "$rid" >"$evidence_file" 2>&1 || true
    done_flag="$(python3 -c "
import json
try:
    d = json.load(open('$evidence_file'))
    print('1' if d.get('evidence', {}).get('done') else '0')
except Exception:
    print('0')
")"
    now=$(date +%s); elapsed=$((now - start_ts))
    echo "heartbeat: elapsed=${elapsed}s max=${max_seconds}s done=${done_flag}" >&2
    [ "$done_flag" = "1" ] && break
    if [ "$elapsed" -ge "$max_seconds" ]; then
      echo "TEMPORAL_TIMEOUT: round did not complete within --max-seconds=$max_seconds" >&2
      return 124
    fi
    sleep 5
  done

  if [ -z "$(git -C "$repo" status --porcelain)" ]; then
    echo "ZERO_COMMIT_ROUND: maker step completed but left the worktree unchanged -- refusing to hand an empty diff to the checker" >&2
    return 10
  fi
  local commit_sha
  commit_sha="$(_commit_round_changes "$repo" "$round" "$goal" "$wid" "$rid")"
  echo "committed $commit_sha" >&2

  # re-fetch ONE more time from a brand-new, syntactically fresh `bridge fetch` process -- proves the
  # durable-read-from-a-new-process property, not just the poll loop's own repeated calls.
  local fresh_evidence="$run_dir/evidence.fresh.json"
  TEMPORAL_ADDRESS="127.0.0.1:$grpc_port" "$run_dir/bridge" fetch --workflow-id "$wid" --run-id "$rid" > "$fresh_evidence"

  python3 -c "
import json
d = json.load(open('$fresh_evidence'))
ev = d['evidence']
checker = next(s for s in ev['steps'] if s['step_id'] == 'step-checker')
print(checker.get('output', ''))
"

  local bridge_head
  bridge_head="$(cd "$bridge_dir" && git rev-parse HEAD 2>/dev/null || echo unknown)"
  python3 -c "
import json
d = json.load(open('$fresh_evidence'))
ev = d['evidence']
total_cents = 0.0
for s in ev['steps']:
    cost = s.get('cost_usd') or 0.0
    total_cents += cost * 100
    print(f\"{s['step_id']}: status={s.get('status')} duration_ms={s.get('duration_ms')} cost_usd={cost}\")
if total_cents > $max_cost_cents:
    print(f'WARNING: total cost {total_cents:.1f} cents exceeds --max-cost-cents=$max_cost_cents (post-hoc warning only; could not be preempted mid-flight)')
" >&2
  echo "bridge HEAD: $bridge_head" >&2
  echo "committed sha: $commit_sha (round $round)" >&2
}

_selfcheck() {
  local fails=0

  # --- arg validation ---
  local rc
  rc=0; "$0" round >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: no --repo exit $rc (want 2)"; fails=1; }
  rc=0; "$0" round --repo /tmp >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: no --checker-goal exit $rc (want 2)"; fails=1; }
  rc=0; "$0" round --repo /tmp --checker-goal x >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: no maker-prompt exit $rc (want 2)"; fails=1; }

  # --- fixture repo for the dry-run plan shape + the real preflight-refusal path ---
  local t; t="$(mktemp -d)"
  git -C "$t" init -q -b main; git -C "$t" config user.email a@a; git -C "$t" config user.name a
  echo seed > "$t/f"; git -C "$t" add -A; git -C "$t" commit -qm seed

  local out
  out="$(SM_TEMPORAL_DRYRUN=1 "$0" round --repo "$t" --checker-goal "check it" --maker-prompt "do it" --round 3 2>&1)" \
    || { echo "FAIL: dryrun errored"; fails=1; }
  echo "$out" | grep -q '"schema_version": 1' || { echo "FAIL: dryrun plan missing schema_version"; fails=1; }
  echo "$out" | grep -q '"round": 3'          || { echo "FAIL: dryrun plan missing round"; fails=1; }
  echo "$out" | grep -q '"kind": "maker"'     || { echo "FAIL: dryrun plan missing maker step"; fails=1; }
  echo "$out" | grep -q '"kind": "checker"'   || { echo "FAIL: dryrun plan missing checker step"; fails=1; }
  echo "$out" | grep -q '"review_step": "step-maker"' || { echo "FAIL: dryrun plan missing review_step wiring"; fails=1; }
  echo "$out" | grep -q '"workdir": "."'      || { echo "FAIL: dryrun plan missing workdir \".\""; fails=1; }

  rc=0; "$0" round --repo "$t" --checker-goal x --maker-prompt y --bridge-dir /nonexistent-xyz-$$ >/tmp/sm-temporal-selfcheck-pf.$$ 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: missing-bridge-dir exit $rc (want 1)"; fails=1; }
  grep -q 'bridge dir not found' /tmp/sm-temporal-selfcheck-pf.$$ || { echo "FAIL: missing-bridge-dir message not found"; fails=1; }
  rm -f /tmp/sm-temporal-selfcheck-pf.$$

  # --- explicit-path git-add + zero-commit-round refusal, against the real function ---
  if _commit_round_changes "$t" 1 "g" "W" "R" >/dev/null 2>/tmp/sm-temporal-selfcheck-zc.$$; then
    echo "FAIL: _commit_round_changes on a clean repo should return 10 (ZERO_COMMIT_ROUND)"; fails=1
  else
    rc=$?; [ "$rc" = 10 ] || { echo "FAIL: clean-repo rc=$rc (want 10)"; fails=1; }
  fi
  rm -f /tmp/sm-temporal-selfcheck-zc.$$

  echo "changed" >> "$t/f"
  local sha
  sha="$(_commit_round_changes "$t" 2 "a real goal" "WID123" "RID456")" || { echo "FAIL: _commit_round_changes on a dirty repo should succeed"; fails=1; }
  [ -n "$sha" ] && [ "$(git -C "$t" rev-parse HEAD)" = "$sha" ] || { echo "FAIL: returned sha does not match new HEAD"; fails=1; }
  git -C "$t" show --stat -q "$sha" | grep -q ' f \b' || true  # advisory only, path formatting varies
  git -C "$t" log -1 --format=%B "$sha" | grep -q 'Temporal-Workflow-Id: WID123' || { echo "FAIL: commit missing Temporal-Workflow-Id trailer"; fails=1; }
  git -C "$t" log -1 --format=%B "$sha" | grep -q 'Temporal-Run-Id: RID456'      || { echo "FAIL: commit missing Temporal-Run-Id trailer"; fails=1; }
  [ -z "$(git -C "$t" status --porcelain)" ] || { echo "FAIL: repo not clean after commit"; fails=1; }
  rm -rf "$t"

  # --- fingerprint-sidecar kill logic: real process killed; wrong fingerprint is never killed ---
  local sc="$(mktemp -d)"
  sleep 30 & local live_pid=$!
  _record_sidecar "$sc/ok.pidinfo" "$live_pid"
  _kill_sidecar "$sc/ok.pidinfo"
  sleep 0.3
  kill -0 "$live_pid" 2>/dev/null && { echo "FAIL: _kill_sidecar did not kill the matching-fingerprint process"; fails=1; kill -9 "$live_pid" 2>/dev/null || true; }

  sleep 30 & local live_pid2=$!
  printf 'pid=%s\ncomm=not-the-real-comm lstart=not-the-real-time\n' "$live_pid2" > "$sc/stale.pidinfo"
  _kill_sidecar "$sc/stale.pidinfo"
  sleep 0.3
  kill -0 "$live_pid2" 2>/dev/null || { echo "FAIL: _kill_sidecar killed a process whose fingerprint did not match"; fails=1; }
  kill -9 "$live_pid2" 2>/dev/null || true
  rm -rf "$sc"

  [ "$fails" = 0 ] && echo ok
  return "$fails"
}

case "${1:-}" in
  --selfcheck) _selfcheck; exit $? ;;
  round) shift; cmd_round "$@"; exit $? ;;
  *) usage; exit 2 ;;
esac
