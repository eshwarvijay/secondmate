#!/usr/bin/env bash
# SessionStart hook: auto-surface durable open decisions so a restart never drops a pending gate.
# Reads the ledger in the session's CWD ($SM_HOLD_LEDGER or ./decisions.jsonl). Emits nothing when empty.
# `hold.py open`'s own output already renders both single-task holds and consolidated batch holds (one
# line per batch entry, task-id + checked-sha + digest) -- nothing here needs to distinguish the two.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--selfcheck" ]; then
  # Exercises the REAL CLI path (this exact script, invoked as a real subprocess, calling the REAL
  # hold.py against a scratch ledger) -- never a reimplementation of hold.py's own open/render logic.
  t="$(mktemp -d)"; fails=0
  ledger="$t/decisions.jsonl"

  # ---- Test 1: no open decisions at all -> no output, exit 0 ----
  rc=0; out="$(SM_HOLD_LEDGER="$ledger" "$0" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: an empty ledger should exit 0, got $rc"; fails=1; }
  [ -z "$out" ] || { echo "FAIL: an empty ledger should print nothing, got: $out"; fails=1; }

  # ---- Test 2: an old-style single-task hold is surfaced with its header + question ----
  SM_HOLD_LEDGER="$ledger" python3 "$SCRIPT_DIR/hold.py" hold --task demo --q "merge demo?" --sha deadbeef >/dev/null
  rc=0; out="$(SM_HOLD_LEDGER="$ledger" "$0" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: expected exit 0 with one open single-task hold, got $rc"; fails=1; }
  echo "$out" | grep -q "OPEN DECISIONS" || { echo "FAIL: expected the OPEN DECISIONS header: $out"; fails=1; }
  echo "$out" | grep -q "merge demo?" || { echo "FAIL: expected the single-task hold's question surfaced: $out"; fails=1; }

  # ---- Test 3: a NEW consolidated batch hold is ALSO surfaced, alongside the single-task hold, with
  # its per-entry task-id/checked-sha/digest -- proving this hook's behavior actually covers both hold
  # shapes, not just the old one. ----
  vfile="$t/v.out"
  printf '```json\n{"verdict":"pass","findings":[]}\n```\n' > "$vfile"
  entries="$t/entries.json"
  printf '[{"task_id":"batch-x","checked_sha":"sha-x","checker_verdict_path":"%s"}]' "$vfile" > "$entries"
  SM_HOLD_LEDGER="$ledger" python3 "$SCRIPT_DIR/hold.py" hold --task batch-1 --q "merge batch?" --entries-file "$entries" >/dev/null
  rc=0; out="$(SM_HOLD_LEDGER="$ledger" "$0" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: expected exit 0 with a batch hold also open, got $rc"; fails=1; }
  echo "$out" | grep -q "batch-x" || { echo "FAIL: expected the batch hold's task-id surfaced: $out"; fails=1; }
  echo "$out" | grep -q "sha-x" || { echo "FAIL: expected the batch hold's checked-sha surfaced: $out"; fails=1; }
  echo "$out" | grep -q "merge demo?" || { echo "FAIL: the single-task hold must still be surfaced alongside the batch hold: $out"; fails=1; }

  rm -rf "$t"
  [ "$fails" = 0 ] && echo ok
  exit "$fails"
fi

out="$(python3 "$SCRIPT_DIR/hold.py" open 2>/dev/null || true)"
[ -n "$out" ] && printf 'OPEN DECISIONS (durable holds — reconcile before new work):\n%s\n' "$out"
exit 0
