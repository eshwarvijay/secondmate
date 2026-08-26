#!/usr/bin/env bash
# prune-output.sh -- deterministic head/tail truncation of oversized output (dsh steal #5, tool-result-pruner).
# Keeps the first HEAD and last TAIL chars, drops the middle. Model-free; run BEFORE feeding a log to a maker/checker.
#   prune-output.sh [FILE]        # FILE or stdin -> pruned text on stdout
#   prune-output.sh --selfcheck
# Tunables (env): THRESHOLD(8192) HEAD(4096) TAIL(1024) chars.
# ponytail: bash substrings are char-based in a UTF-8 locale, byte-based in C — fine for log pruning.
set -euo pipefail

TH="${THRESHOLD:-8192}"; HEAD="${HEAD:-4096}"; TAIL="${TAIL:-1024}"

if [ "${1:-}" = "--selfcheck" ]; then
  out="$(printf 'ABCDEFGHIJKLMNOPQRST' | THRESHOLD=10 HEAD=3 TAIL=2 "$0")"
  echo "$out" | grep -q 'pruned' || { echo "FAIL: over-threshold not pruned"; exit 1; }
  small="$(printf 'abc' | THRESHOLD=10 "$0")"
  [ "$small" = "abc" ] || { echo "FAIL: under-threshold changed"; exit 1; }
  echo ok; exit 0
fi

data="$(cat "${1:-/dev/stdin}")"
n=${#data}
if [ "$n" -le "$TH" ]; then printf '%s' "$data"; exit 0; fi
printf '%s\n\n[... %d chars of output middle pruned ...]\n\n%s' \
  "${data:0:$HEAD}" "$((n - HEAD - TAIL))" "${data: -$TAIL}"
