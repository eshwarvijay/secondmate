#!/usr/bin/env bash
# SessionStart hook: auto-surface durable open decisions so a restart never drops a pending gate.
# Reads the ledger in the session's CWD ($SM_HOLD_LEDGER or ./decisions.jsonl). Emits nothing when empty.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(python3 "$SCRIPT_DIR/hold.py" open 2>/dev/null || true)"
[ -n "$out" ] && printf 'OPEN DECISIONS (durable holds — reconcile before new work):\n%s\n' "$out"
exit 0
