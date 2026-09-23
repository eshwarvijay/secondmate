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
# ABORT_REPEATS controls the no-progress loop_abort threshold.
# If ABORT_REPEATS <= 3, the exit-5 restart range becomes empty (every repeat goes straight to hard-abort).
ABORT_REPEATS="${ABORT_REPEATS:-10}"; MAX_ROUNDS="${MAX_ROUNDS:-256}"; MAX_SPAWNS="${MAX_SPAWNS:-1000}"

# C-fix: mkdir is an atomic, cross-platform lock (macOS has no flock). Serializes the counter
# read-modify-write when parallel makers share one $SM_LOOP_STATE. The trap releases on any exit
# except SIGKILL; a kill in the ~microsecond critical section is self-healed by `reset`.
_unlock() { rmdir "$state/.lock" 2>/dev/null || true; }
_lock() { local i=0; until mkdir "$state/.lock" 2>/dev/null; do i=$((i + 1)); [ "$i" -ge 40 ] && return 1; sleep 0.05; done; trap _unlock EXIT; }

cmd="${1:-}"; [ $# -gt 0 ] && shift

case "$cmd" in
  action)
    key=""
    while [ $# -gt 0 ]; do case "$1" in --key) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; key="$2"; shift 2;; *) shift;; esac; done
    [ -n "$key" ] || { echo "need --key" >&2; exit 2; }
    mkdir -p "$state"
    h="$(printf '%s' "$key" | shasum -a 256 | cut -d' ' -f1)"
    _lock || echo "loop-guard: lock busy, counting unlocked" >&2
    prev="$(cat "$state/action.key" 2>/dev/null || true)"
    n="$(cat "$state/action.count" 2>/dev/null || echo 0)"
    if [ "$h" = "$prev" ]; then n=$((n + 1)); else n=1; printf '%s' "$h" >"$state/action.key"; fi
    echo "$n" >"$state/action.count"
    case "$n" in
      1|2) exit 0;;
      *)
        if [ "$n" -ge "$ABORT_REPEATS" ]; then
          echo "ABORT: no-progress loop (${n}x identical action)"; exit 3
        else
          echo "RESTART: identical action ${n}x — kill this maker and restart fresh with the round-state handoff file."; exit 5
        fi;;
    esac;;
  round)
    mkdir -p "$state"
    _lock || echo "loop-guard: lock busy, counting unlocked" >&2
    r="$(cat "$state/rounds" 2>/dev/null || echo 0)"; r=$((r + 1)); echo "$r" >"$state/rounds"
    s="$(cat "$state/spawns" 2>/dev/null || echo 0)"; s=$((s + 1)); echo "$s" >"$state/spawns"
    if [ "$s" -gt "$MAX_SPAWNS" ]; then echo "budget-limited: spawn cap $MAX_SPAWNS reached"; exit 4; fi
    if [ "$r" -gt "$MAX_ROUNDS" ]; then echo "budget-limited: round cap $MAX_ROUNDS reached"; exit 4; fi
    echo "round=$r spawns=$s"; exit 0;;
  reset)
    # finding #3: delete ONLY the files we create, never `rm -rf` the caller's $SM_LOOP_STATE wholesale.
    rm -f "$state/action.key" "$state/action.count" "$state/rounds" "$state/spawns" 2>/dev/null || true
    rmdir "$state/.lock" 2>/dev/null || true   # clear a stale lock from a SIGKILL'd critical section
    rmdir "$state" 2>/dev/null || true
    echo "loop state cleared"; exit 0;;
  selfcheck)
    tmp="$(mktemp -d)"; r=0
    # Full exit-code walk-through for two ABORT_REPEATS values: n<3 exit0 silent,
    # 3<=n<ABORT_REPEATS exit5 RESTART, n>=ABORT_REPEATS exit3 ABORT.
    # Each n is checked from exactly ONE call (never re-invoked to "recheck a message" --
    # loop-guard.sh action is stateful, a second call always advances the counter again).
    for AR in 5 10; do
      rm -f "$tmp/action.key" "$tmp/action.count"
      for n in $(seq 1 $((AR + 1))); do
        set +e
        out="$(SM_LOOP_STATE="$tmp" ABORT_REPEATS="$AR" "$0" action --key same 2>&1)"; ec=$?
        set -e
        cnt="$(cat "$tmp/action.count" 2>/dev/null || echo '?')"
        [ "$cnt" = "$n" ] || { echo "FAIL: ABORT=$AR, n=$n count should be $n, got $cnt"; r=1; }
        if [ "$n" -lt 3 ]; then
          { [ "$ec" = 0 ] && [ -z "$out" ]; } || { echo "FAIL: ABORT=$AR, n=$n should be exit 0 silent, got ec=$ec out=$out"; r=1; }
        elif [ "$n" -lt "$AR" ]; then
          [ "$ec" = 5 ] || { echo "FAIL: ABORT=$AR, n=$n should be exit 5, got $ec"; r=1; }
          printf '%s' "$out" | grep -q RESTART || { echo "FAIL: ABORT=$AR, n=$n missing RESTART message"; r=1; }
        else
          [ "$ec" = 3 ] || { echo "FAIL: ABORT=$AR, n=$n should be exit 3, got $ec"; r=1; }
          printf '%s' "$out" | grep -q ABORT || { echo "FAIL: ABORT=$AR, n=$n missing ABORT message"; r=1; }
        fi
      done
    done
    # Test new key resets count
    rm -f "$tmp/action.key" "$tmp/action.count"
    SM_LOOP_STATE="$tmp" ABORT_REPEATS=10 "$0" action --key different >/dev/null 2>&1 || true
    [ "$(cat "$tmp/action.count")" = "1" ] || { echo "FAIL: new key should reset count"; r=1; }
    # Round cap test
    SM_LOOP_STATE="$tmp" MAX_ROUNDS=2 "$0" round >/dev/null 2>&1
    SM_LOOP_STATE="$tmp" MAX_ROUNDS=2 "$0" round >/dev/null 2>&1
    if SM_LOOP_STATE="$tmp" MAX_ROUNDS=2 "$0" round >/dev/null 2>&1; then echo "FAIL: round cap not enforced"; r=1; fi
    # C-fix: 8 concurrent increments must all land (atomic lock, no lost updates).
    tmp2="$(mktemp -d)"; for _ in 1 2 3 4 5 6 7 8; do SM_LOOP_STATE="$tmp2" ABORT_REPEATS=99 "$0" action --key k >/dev/null 2>&1 & done; wait
    [ "$(cat "$tmp2/action.count" 2>/dev/null || echo 0)" = "8" ] || { echo "FAIL: concurrent count lost updates ($(cat "$tmp2/action.count" 2>/dev/null))"; r=1; }
    rm -rf "$tmp" "$tmp2"; [ "$r" = 0 ] && echo ok; exit "$r";;
  *) echo "usage: loop-guard.sh action --key K | round | reset | selfcheck" >&2; exit 2;;
esac
