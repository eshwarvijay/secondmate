#!/usr/bin/env bash
# herdr-pane.sh -- helper for VISIBLE side-by-side orchestration when running inside herdr.
# Splits from the CURRENT (supervisor) pane, preserves the user's focus and cwd, and prints the new pane id.
# Requires HERDR_ENV=1 and the `herdr` CLI. Used by the skill's visible-orchestration path; headless otherwise.
#   herdr-pane.sh check              -> exit 0 if usable (inside herdr + herdr on PATH), else 1
#   herdr-pane.sh split [right|down] -> print the new pane_id (default: right)
set -euo pipefail

cmd="${1:-}"; dir="${2:-right}"
usable() { [ "${HERDR_ENV:-}" = 1 ] && command -v herdr >/dev/null 2>&1; }

case "$cmd" in
  check)
    usable || { echo "not usable: need HERDR_ENV=1 and herdr on PATH (fall back to headless orchestration)" >&2; exit 1; }
    ;;
  split)
    usable || { echo "not inside herdr (HERDR_ENV != 1) or herdr missing" >&2; exit 1; }
    case "$dir" in right|down) ;; *) echo "direction must be right|down" >&2; exit 2;; esac
    out="$(herdr pane split --current --direction "$dir" --cwd "$PWD" --no-focus)" || { echo "herdr pane split failed" >&2; exit 1; }
    printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])'
    ;;
  *) echo "usage: herdr-pane.sh check | split [right|down]" >&2; exit 2;;
esac
