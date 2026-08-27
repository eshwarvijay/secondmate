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
    --label) label="${2:?value required for $1}"; shift 2;; --log) log="${2:?value required for $1}"; shift 2;;
    --timeout) timeout_s="${2:?value required for $1}"; shift 2;; --idle) idle_s="${2:?value required for $1}"; shift 2;;
    --audit) audit="${2:?value required for $1}"; shift 2;; --) shift; break;;
    *) echo "unknown arg: $1" >&2; return 2;; esac; done
  [ $# -gt 0 ] || { echo "need -- <cmd...>" >&2; return 2; }

  # finding #8: JSON-encode the label + event (python) so a crafted --label can't forge audit records.
  audit_line() { python3 -c 'import json,sys; print(json.dumps({"label":sys.argv[1],"event":sys.argv[2],"ts":int(sys.argv[3])},separators=(",",":")))' "$label" "$1" "$(date +%s)" >>"$audit"; }

  mkdir -p "$(dirname "$audit")" 2>/dev/null || true   # finding #5: ensure the audit dir exists so records actually land
  audit_line start
  local status=0 reason="" start last_size=0 last_change now sz pid
  : >"$log"
  "$@" >"$log" 2>&1 &
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
    kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null || true
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
  rm -rf "$tmp"; [ "$rc" = 0 ] && echo ok; exit "$rc"
fi

run "$@"; exit $?
