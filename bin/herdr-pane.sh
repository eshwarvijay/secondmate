#!/usr/bin/env bash
# herdr-pane.sh -- helpers for VISIBLE side-by-side orchestration inside herdr.
# Splits from the CURRENT (supervisor) pane, preserves the user's focus (--no-focus) and cwd.
# Requires HERDR_ENV=1 and the `herdr` CLI.
#
#   herdr-pane.sh check                 -> exit 0 if usable (inside herdr + herdr on PATH)
#   herdr-pane.sh split [right|down]    -> print the new pane_id
#   herdr-pane.sh spawn    --name N --kind K [--dir right|down] [--cwd DIR] [-- <agent args...>]
#         split a pane, WAIT until its shell is ready (race-proof), start a live agent -> prints "<name> <pane_id>"
#   herdr-pane.sh delegate --name N --kind K [--dir right|down] [--cwd DIR] --prompt TEXT [--timeout MS] [-- <agent args...>]
#         spawn, send the prompt, wait for the agent to settle, then print its harvested output
#
# KINDS: claude pi codex gemini cursor grok kimi opencode ... (herdr agent start --kind).
# Note: a live MAKER writes files (read the diff via git — no output parsing needed). For a CHECKER whose
# {verdict} you must PARSE, prefer the headless-in-pane recipe (launch-checker ... -- -p) for clean stdout.
set -uo pipefail

usable() { [ "${HERDR_ENV:-}" = 1 ] && command -v herdr >/dev/null 2>&1; }
pane_id() { python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])'; }

do_split() { # dir cwd -> pane_id
  case "$1" in right|down) ;; *) echo "direction must be right|down" >&2; return 2;; esac
  herdr pane split --current --direction "$1" --cwd "$2" --no-focus | pane_id
}

# Start a live agent in <pane>, retrying until the pane's shell is actually ready. This fixes the
# "not an available shell" / agent_pane_busy race on a freshly-split pane (no manual sleep needed).
start_agent() { # name kind pane [-- agent args...]
  local name="$1" kind="$2" pane="$3"; shift 3
  local i out
  for i in $(seq 1 20); do
    if [ "$#" -gt 0 ]; then out="$(herdr agent start "$name" --kind "$kind" --pane "$pane" -- "$@" 2>&1)" || true
    else out="$(herdr agent start "$name" --kind "$kind" --pane "$pane" 2>&1)" || true; fi
    case "$out" in
      *'"agent_started"'*|*'"agent_info"'*|*already*|*exists*|*duplicate*) return 0;;
      *) sleep 1;;   # busy / not-yet-a-shell / transient — keep trying within the ~20s window
    esac
  done
  echo "agent start failed after retries: $out" >&2; return 1
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  check) usable || { echo "not usable: need HERDR_ENV=1 and herdr on PATH (fall back to headless)" >&2; exit 1; };;
  --selfcheck)
    fails=0
    rc=0; "$0" bogusverb >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: unknown verb exit $rc (want 2)"; fails=1; }
    if usable; then  # validate-before-mutate: delegate w/o --prompt must exit 2 and create NO pane
      count() { herdr pane list --workspace "${HERDR_WORKSPACE_ID:-}" 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["result"]["panes"]))' 2>/dev/null || echo 0; }
      b="$(count)"; rc=0; "$0" delegate --name _sc --kind pi >/dev/null 2>&1 || rc=$?; a="$(count)"
      { [ "$rc" = 2 ] && [ "$b" = "$a" ]; } || { echo "FAIL: delegate validate-before-split (rc=$rc panes $b->$a)"; fails=1; }
    fi
    [ "$fails" = 0 ] && echo ok; exit "$fails";;
  split)
    usable || { echo "not inside herdr" >&2; exit 1; }
    do_split "${1:-right}" "$PWD";;
  spawn|delegate)
    usable || { echo "not inside herdr" >&2; exit 1; }
    name="" kind="" dir="right" cwd="$PWD" prompt="" timeout=600000; args=()
    while [ $# -gt 0 ]; do case "$1" in
      --name) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; name="$2"; shift 2;; --kind) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; kind="$2"; shift 2;;
      --dir) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; dir="$2"; shift 2;; --cwd) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; cwd="$2"; shift 2;;
      --prompt) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; prompt="$2"; shift 2;; --timeout) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; timeout="$2"; shift 2;;
      --) shift; args=("$@"); break;;
      *) echo "unknown arg: $1" >&2; exit 2;;
    esac; done
    [ -n "$name" ] && [ -n "$kind" ] || { echo "need --name and --kind" >&2; exit 2; }
    # finding #2: validate ALL required args BEFORE mutating (splitting a pane), so a bad call leaves nothing behind.
    if [ "$cmd" = delegate ] && [ -z "$prompt" ]; then echo "delegate needs --prompt" >&2; exit 2; fi
    pane="$(do_split "$dir" "$cwd")" || exit 1
    if [ "${#args[@]}" -gt 0 ]; then start_agent "$name" "$kind" "$pane" "${args[@]}" || exit 1
    else start_agent "$name" "$kind" "$pane" || exit 1; fi
    if [ "$cmd" = spawn ]; then
      echo "$name $pane"
    else
      [ -n "$prompt" ] || { echo "delegate needs --prompt" >&2; exit 2; }
      # finding #7: do NOT mask a failed/timed-out prompt — otherwise stale `agent read` output looks like success.
      herdr agent prompt "$name" "$prompt" --wait --timeout "$timeout" >/dev/null 2>&1 \
        || { echo "delegate: prompt to $name failed or timed out" >&2; exit 1; }
      herdr agent read "$name" --source recent-unwrapped --lines 400
    fi;;
  *) echo "usage: herdr-pane.sh check | split [right|down] | spawn --name N --kind K [...] | delegate --name N --kind K --prompt T [...]" >&2; exit 2;;
esac
