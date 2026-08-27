#!/usr/bin/env bash
# run-round.sh -- run one maker/checker invocation with a wall-clock timeout, an idle (no-output-growth)
# watchdog, and a paired audit record even on kill.
# macOS ships no timeout(1), so this polls itself.
#   run-round.sh --label NAME [--log F] [--timeout 600] [--idle 120] [--audit F] -- <cmd...>
#   run-round.sh selfcheck
# Exit: the command's own code, or 124 = wall-clock timeout, 125 = idle. Always appends an end-record to the audit log.
set -uo pipefail

run() {
  local label="round" log="round.log" timeout_s=600 idle_s=120 audit="audit.jsonl" poll="${POLL:-5}"
  while [ $# -gt 0 ]; do case "$1" in
    --label) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; label="$2"; shift 2;; --log) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; log="$2"; shift 2;;
    --timeout) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; timeout_s="$2"; shift 2;; --idle) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; idle_s="$2"; shift 2;;
    --audit) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; audit="$2"; shift 2;; --) shift; break;;
    *) echo "unknown arg: $1" >&2; return 2;; esac; done
  [ $# -gt 0 ] || { echo "need -- <cmd...>" >&2; return 2; }

  # finding #8: JSON-encode the label + event (python) so a crafted --label can't forge audit records.
  audit_line() { python3 -c 'import json,sys; print(json.dumps({"label":sys.argv[1],"event":sys.argv[2],"ts":int(sys.argv[3])},separators=(",",":")))' "$label" "$1" "$(date +%s)" >>"$audit"; }

  mkdir -p "$(dirname "$audit")" 2>/dev/null || true   # finding #5: ensure the audit dir exists so records actually land
  audit_line start
  local status=0 reason="" start last_size=0 last_change now sz pid
  : >"$log"
  # C-fix: run the command as a session/process-group leader so a timeout kills its whole tree,
  # not just the top process (macOS has no setsid(1); python3 os.setsid does it portably).
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" >"$log" 2>&1 &
  else
    "$@" >"$log" 2>&1 &   # no python3: fall back to single-process (descendants may survive a timeout)
  fi
  pid=$!
  trap 'audit_line killed-trap 2>/dev/null || true' EXIT   # paired end-record even if WE are killed
  start=$(date +%s); last_change=$start
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$poll"
    now=$(date +%s); sz=$(wc -c <"$log" 2>/dev/null || echo 0)
    [ "$sz" -ne "$last_size" ] && { last_size=$sz; last_change=$now; }
    if [ $((now - start)) -ge "$timeout_s" ]; then reason=TIMEOUT; break; fi
    if [ $((now - last_change)) -ge "$idle_s" ]; then reason=IDLE; break; fi
  done
  if [ -n "$reason" ]; then
    # negative pid = the whole process group (the setsid tree); fall back to the bare pid if it isn't a leader.
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    case "$reason" in TIMEOUT) audit_line wall-timeout; status=124;; IDLE) audit_line idle-timeout; status=125;; esac
  else
    wait "$pid"; status=$?
    audit_line "exit-$status"
  fi
  trap - EXIT
  return "$status"
}

if [ "${1:-}" = "selfcheck" ]; then
  tmp="$(mktemp -d)"; rc=0
  POLL=1 run --label t1 --log "$tmp/l1" --audit "$tmp/a" --timeout 1 --idle 30 -- sleep 5; c=$? || true
  [ "$c" = "124" ] || { echo "FAIL: wall-timeout expected 124 got $c"; rc=1; }
  POLL=1 run --label t2 --log "$tmp/l2" --audit "$tmp/a" --timeout 30 --idle 1 -- sleep 5; c=$? || true
  [ "$c" = "125" ] || { echo "FAIL: idle expected 125 got $c"; rc=1; }
  POLL=1 run --label t3 --log "$tmp/l3" --audit "$tmp/a" --timeout 5 -- sh -c 'echo hi'; c=$? || true
  [ "$c" = "0" ] || { echo "FAIL: ok expected 0 got $c"; rc=1; }
  grep -q '"event":"exit-0"' "$tmp/a" || { echo "FAIL: missing exit-0 audit record"; rc=1; }
  # C-fix: a wall-timeout must kill the whole process tree. Launch a backgrounded grandchild, record its
  # pid, time out the parent, then assert the grandchild is dead (it survives if we only killed the leader).
  POLL=1 run --label t4 --log "$tmp/l4" --audit "$tmp/a" --timeout 1 --idle 30 -- sh -c 'sleep 30 & echo $! > '"$tmp"'/gpid; wait' >/dev/null 2>&1 || true
  sleep 1; gp="$(cat "$tmp/gpid" 2>/dev/null || echo)"
  if [ -n "$gp" ] && kill -0 "$gp" 2>/dev/null; then echo "FAIL: descendant $gp survived timeout"; kill -KILL "$gp" 2>/dev/null || true; rc=1; fi
  rm -rf "$tmp"; [ "$rc" = 0 ] && echo ok; exit "$rc"
fi

run "$@"; exit $?
