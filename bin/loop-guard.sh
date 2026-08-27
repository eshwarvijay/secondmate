#!/usr/bin/env bash
# loop-guard.sh -- loop safety for the maker/checker loop: stuck-loop detection + bounded iteration.
#   loop-guard.sh action --key "<canonical action/diff>"  # consecutive-identical detection; exit 3 = abort (no progress)
#   loop-guard.sh round                                   # bump round+spawn counters; exit 4 = budget exhausted
#   loop-guard.sh reset                                   # clear all state (human interjection / new task)
#   loop-guard.sh selfcheck
# State: $SM_LOOP_STATE or ./.secondmate . Tunables (env): ABORT_REPEATS(10) MAX_ROUNDS(256) MAX_SPAWNS(1000).
# Counts FAILED/denied actions too, and exhaustion is NEVER reported as success.
set -euo pipefail

state="${SM_LOOP_STATE:-.secondmate}"
ABORT_REPEATS="${ABORT_REPEATS:-10}"; MAX_ROUNDS="${MAX_ROUNDS:-256}"; MAX_SPAWNS="${MAX_SPAWNS:-1000}"

cmd="${1:-}"; [ $# -gt 0 ] && shift

case "$cmd" in
  action)
    key=""
    while [ $# -gt 0 ]; do case "$1" in --key) key="${2:?value required for $1}"; shift 2;; *) shift;; esac; done
    [ -n "$key" ] || { echo "need --key" >&2; exit 2; }
    mkdir -p "$state"
    h="$(printf '%s' "$key" | shasum -a 256 | cut -d' ' -f1)"
    prev="$(cat "$state/action.key" 2>/dev/null || true)"
    n="$(cat "$state/action.count" 2>/dev/null || echo 0)"
    if [ "$h" = "$prev" ]; then n=$((n + 1)); else n=1; printf '%s' "$h" >"$state/action.key"; fi
    echo "$n" >"$state/action.count"
    case "$n" in
      3) echo "HYGIENE: identical action 3x — re-read the last output and change approach.";;
      5|8) echo "HYGIENE: identical action ${n}x, not progressing — do NOT repeat it; pick a different action or stop.";;
    esac
    if [ "$n" -ge "$ABORT_REPEATS" ]; then echo "ABORT: no-progress loop (${n}x identical action)"; exit 3; fi
    exit 0;;
  round)
    mkdir -p "$state"
    r="$(cat "$state/rounds" 2>/dev/null || echo 0)"; r=$((r + 1)); echo "$r" >"$state/rounds"
    s="$(cat "$state/spawns" 2>/dev/null || echo 0)"; s=$((s + 1)); echo "$s" >"$state/spawns"
    if [ "$s" -gt "$MAX_SPAWNS" ]; then echo "budget-limited: spawn cap $MAX_SPAWNS reached"; exit 4; fi
    if [ "$r" -gt "$MAX_ROUNDS" ]; then echo "budget-limited: round cap $MAX_ROUNDS reached"; exit 4; fi
    echo "round=$r spawns=$s"; exit 0;;
  reset)
    # finding #3: delete ONLY the files we create, never `rm -rf` the caller's $SM_LOOP_STATE wholesale.
    rm -f "$state/action.key" "$state/action.count" "$state/rounds" "$state/spawns" 2>/dev/null || true
    rmdir "$state" 2>/dev/null || true
    echo "loop state cleared"; exit 0;;
  selfcheck)
    tmp="$(mktemp -d)"; r=0
    SM_LOOP_STATE="$tmp" ABORT_REPEATS=4 "$0" action --key same >/dev/null 2>&1 || true
    SM_LOOP_STATE="$tmp" ABORT_REPEATS=4 "$0" action --key same >/dev/null 2>&1 || true
    o3="$(SM_LOOP_STATE="$tmp" ABORT_REPEATS=4 "$0" action --key same 2>&1 || true)"
    echo "$o3" | grep -q HYGIENE || { echo "FAIL: no reminder at 3rd repeat"; r=1; }
    if SM_LOOP_STATE="$tmp" ABORT_REPEATS=4 "$0" action --key same >/dev/null 2>&1; then echo "FAIL: should abort at 4th"; r=1; fi
    SM_LOOP_STATE="$tmp" ABORT_REPEATS=4 "$0" action --key other >/dev/null 2>&1 || true
    [ "$(cat "$tmp/action.count" 2>/dev/null)" = "1" ] || { echo "FAIL: new key should reset count"; r=1; }
    SM_LOOP_STATE="$tmp" MAX_ROUNDS=2 "$0" round >/dev/null 2>&1
    SM_LOOP_STATE="$tmp" MAX_ROUNDS=2 "$0" round >/dev/null 2>&1
    if SM_LOOP_STATE="$tmp" MAX_ROUNDS=2 "$0" round >/dev/null 2>&1; then echo "FAIL: round cap not enforced"; r=1; fi
    rm -rf "$tmp"; [ "$r" = 0 ] && echo ok; exit "$r";;
  *) echo "usage: loop-guard.sh action --key K | round | reset | selfcheck" >&2; exit 2;;
esac
