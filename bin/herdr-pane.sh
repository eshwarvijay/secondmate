#!/usr/bin/env bash
# herdr-pane.sh -- helpers for VISIBLE side-by-side orchestration inside herdr.
# Splits from the CURRENT (supervisor) pane by default (--current), preserves the user's focus (--no-focus) and cwd.
# When --pane <ID> is given, splits from that specific pane instead (useful for routing panes into a dedicated worktree).
# Requires HERDR_ENV=1 and the `herdr` CLI.
#
#   herdr-pane.sh check                 -> exit 0 if usable (inside herdr + herdr on PATH)
#   herdr-pane.sh split [--pane <ID>] [--dir right|down] -> print the new pane_id
#   herdr-pane.sh spawn    --name N --kind K [--pane <ID>] [--dir right|down] [--cwd DIR] [-- <agent args...>]
#         split a pane, WAIT until its shell is ready (race-proof), start a live agent -> prints "<name> <pane_id>"
#   herdr-pane.sh delegate --name N --kind K [--pane <ID>] [--dir right|down] [--cwd DIR] --prompt TEXT [--timeout MS] [-- <agent args...>]
#         spawn, send the prompt, wait for the agent to settle, then print its harvested output
#
# KINDS: claude pi codex gemini cursor grok kimi opencode ... (herdr agent start --kind).
# Note: a live MAKER writes files (read the diff via git — no output parsing needed). For a CHECKER whose
# {verdict} you must PARSE, prefer the headless-in-pane recipe (launch-checker ... -- -p) for clean stdout.
set -uo pipefail

usable() { [ "${HERDR_ENV:-}" = 1 ] && command -v herdr >/dev/null 2>&1; }
pane_id() { python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])'; }

do_split() { # pane_id? dir cwd -> pane_id
  local pane_flag="$1"
  local dir="$2"; local cwd="$3"
  case "$dir" in right|down) ;; *) echo "direction must be right|down" >&2; return 2;; esac
  local split_args=(--direction "$dir" --cwd "$cwd" --no-focus)
  if [ -n "$pane_flag" ]; then
    split_args=(--pane "$pane_flag" "${split_args[@]}")
  else
    split_args=(--current "${split_args[@]}")
  fi
  herdr pane split "${split_args[@]}" | pane_id
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
    # Test arg parsing without running real herdr: use mock herdr in temp dir
    if usable; then
      # validate-before-mutate: delegate w/o --prompt must exit 2 and create NO pane
      count() { herdr pane list --workspace "${HERDR_WORKSPACE_ID:-}" 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["result"]["panes"]))' 2>/dev/null || echo 0; }
      b="$(count)"; rc=0; "$0" delegate --name _sc --kind pi >/dev/null 2>&1 || rc=$?; a="$(count)"
      { [ "$rc" = 2 ] && [ "$b" = "$a" ]; } || { echo "FAIL: delegate validate-before-split (rc=$rc panes $b->$a)"; fails=1; }
    fi
    # Mock-based tests for split/spawn/delegate arg parsing (no real panes created)
    tmpdir="$(mktemp -d)"
    mock_herdr="$tmpdir/herdr"
    log_file="$tmpdir/herdr.log"
    # Create mock herdr that logs argv and returns fake pane_id
    cat > "$mock_herdr" << 'HERDMOCK'
#!/usr/bin/env bash
echo "$*" >> "${HERDR_MOCK_LOG:-/tmp/herdr-mock.log}"
case "$1" in
  pane)
    case "$2" in
      split) echo '{"result":{"pane":{"pane_id":"mock-pane-'"$RANDOM"'"}}}';;
      list) echo '{"result":{"panes":[]}}';;
      *) exit 1;;
    esac;;
  agent)
    case "$2" in
      start) echo '{"result":{"agent_info":{"agent_name":'$4'}}}';;
      prompt|read) exit 0;;
      *) exit 1;;
    esac;;
  worktree)
    case "$2" in
      create) echo '{"result":{"worktree":{"path":"/mock"},"root_pane":{"pane_id":"mock-root-'$RANDOM'"}}}';;
      remove) exit 0;;
      *) exit 1;;
    esac;;
  *) exit 1;;
esac
HERDMOCK
    chmod +x "$mock_herdr"
    # Get the repo root (one level up from bin/)
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    repo_root="$(dirname "$script_dir")"
    # Run tests with mock herdr on PATH (HERDR_ENV still required since check needs it)
    # First set up mock herdr in PATH then run the check to verify it's on PATH
    env PATH="$tmpdir:$PATH" HERDR_ENV=1 herdr pane list >/dev/null 2>&1 || { echo "FAIL: mock herdr not on PATH"; fails=1; }
    # Now run the arg parsing tests with HERDR_ENV=1
    env PATH="$tmpdir:$PATH" HERDR_ENV=1 HERDR_MOCK_LOG="$log_file" "$repo_root/bin/herdr-pane.sh" split >/dev/null 2>&1
    rc=$?; [ "$rc" = 0 ] || { echo "FAIL: split without args (rc=$rc)"; fails=1; }
    env PATH="$tmpdir:$PATH" HERDR_ENV=1 HERDR_MOCK_LOG="$log_file" "$repo_root/bin/herdr-pane.sh" split down >/dev/null 2>&1
    rc=$?; [ "$rc" = 0 ] || { echo "FAIL: split with bare down (rc=$rc)"; fails=1; }
    env PATH="$tmpdir:$PATH" HERDR_ENV=1 HERDR_MOCK_LOG="$log_file" "$repo_root/bin/herdr-pane.sh" split --dir right >/dev/null 2>&1
    rc=$?; [ "$rc" = 0 ] || { echo "FAIL: split with --dir (rc=$rc)"; fails=1; }
    # Assert mock herdr was called with --current (backward compat)
    if [ -f "$log_file" ]; then
      # Check last call was for split down (should have --current)
      last_split=$(grep "pane split" "$log_file" | tail -1)
      case "$last_split" in
        *"--current"*) ;; # good
        *) echo "FAIL: split without args did not use --current: $last_split"; fails=1;;
      esac
    fi
    # Test split with --pane (must use --pane not --current)
    env PATH="$tmpdir:$PATH" HERDR_ENV=1 HERDR_MOCK_LOG="$log_file" "$repo_root/bin/herdr-pane.sh" split --pane test-pane-123 --dir right >/dev/null 2>&1
    rc=$?; [ "$rc" = 0 ] || { echo "FAIL: split with --pane (rc=$rc)"; fails=1; }
    if [ -f "$log_file" ]; then
      # Check split with --pane test-pane-123 was called and has no --current
      split_pane_line=$(grep -- '--pane test-pane-123' "$log_file" | grep "pane split")
      if [ -n "$split_pane_line" ]; then
        case "$split_pane_line" in
          *"--current"*) echo "FAIL: split with --pane test-pane-123 also had --current: $split_pane_line"; fails=1;;
          *) ;; # good - has --pane, no --current
        esac
      else
        echo "FAIL: split with --pane test-pane-123 was not called"; fails=1
      fi
    fi
    # Test spawn with --pane targeting
    env PATH="$tmpdir:$PATH" HERDR_ENV=1 HERDR_MOCK_LOG="$log_file" "$repo_root/bin/herdr-pane.sh" spawn --name _sc_test --kind pi --pane mock-target-pane --dir down >/dev/null 2>&1
    rc=$?; [ "$rc" = 0 ] || { echo "FAIL: spawn with --pane (rc=$rc)"; fails=1; }
    if [ -f "$log_file" ]; then
      # Check spawn with --pane mock-target-pane was called and has no --current
      spawn_pane_line=$(grep -- '--pane mock-target-pane' "$log_file" | grep "pane split")
      if [ -n "$spawn_pane_line" ]; then
        case "$spawn_pane_line" in
          *"--current"*) echo "FAIL: spawn with --pane mock-target-pane also had --current: $spawn_pane_line"; fails=1;;
          *) ;; # good - has --pane mock-target-pane, no --current
        esac
      else
        echo "FAIL: spawn with --pane mock-target-pane was not called"; fails=1
      fi
    fi
    # Test delegate with --pane targeting
    env PATH="$tmpdir:$PATH" HERDR_ENV=1 HERDR_MOCK_LOG="$log_file" "$repo_root/bin/herdr-pane.sh" delegate --name _sc_del --kind pi --pane delegate-target --dir down --prompt "test prompt" >/dev/null 2>&1
    rc=$?; [ "$rc" = 0 ] || { echo "FAIL: delegate with --pane (rc=$rc)"; fails=1; }
    if [ -f "$log_file" ]; then
      # Check delegate with --pane delegate-target was called and has no --current
      delegate_pane_line=$(grep -- '--pane delegate-target' "$log_file" | grep "pane split")
      if [ -n "$delegate_pane_line" ]; then
        case "$delegate_pane_line" in
          *"--current"*) echo "FAIL: delegate with --pane delegate-target also had --current: $delegate_pane_line"; fails=1;;
          *) ;; # good - has --pane, no --current
        esac
      else
        echo "FAIL: delegate with --pane delegate-target was not called"; fails=1
      fi
    fi
    # Cleanup
    rm -rf "$tmpdir"
    [ "$fails" = 0 ] && echo ok; exit "$fails";;
  split)
    usable || { echo "not inside herdr" >&2; exit 1; }
    pane_id="" dir="right"
    while [ $# -gt 0 ]; do
      case "$1" in
        --pane) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; 
        if [[ "$2" == --* ]]; then echo "$1 value cannot be another flag: '$2'" >&2; exit 2; fi
        pane_id="$2"; shift 2;;
        --dir) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; };
        if [[ "$2" == --* ]]; then echo "$1 value cannot be another flag: '$2'" >&2; exit 2; fi
        dir="$2"; shift 2;;
        --) shift; break;;
        # bare positional direction (backward compat: no --dir flag required)
        right|down) dir="$1"; shift;;
        *) echo "unknown arg: $1" >&2; exit 2;;
      esac
    done
    do_split "$pane_id" "$dir" "$PWD";;
  spawn|delegate)
    usable || { echo "not inside herdr" >&2; exit 1; }
    name="" kind="" dir="right" cwd="$PWD" pane_id="" prompt="" timeout=600000; args=()
    while [ $# -gt 0 ]; do case "$1" in
      --name) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; name="$2"; shift 2;; --kind) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; kind="$2"; shift 2;;
      --dir) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; };
        if [[ "$2" == --* ]]; then echo "$1 value cannot be another flag: '$2'" >&2; exit 2; fi
        dir="$2"; shift 2;; --cwd) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; cwd="$2"; shift 2;;
      --pane) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; 
        if [[ "$2" == --* ]]; then echo "$1 value cannot be another flag: '$2'" >&2; exit 2; fi
        pane_id="$2"; shift 2;;
      --prompt) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; prompt="$2"; shift 2;; --timeout) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; timeout="$2"; shift 2;;
      --) shift; args=("$@"); break;;
      *) echo "unknown arg: $1" >&2; exit 2;;
    esac; done
    [ -n "$name" ] && [ -n "$kind" ] || { echo "need --name and --kind" >&2; exit 2; }
    # finding #2: validate ALL required args BEFORE mutating (splitting a pane), so a bad call leaves nothing behind.
    if [ "$cmd" = delegate ] && [ -z "$prompt" ]; then echo "delegate needs --prompt" >&2; exit 2; fi
    pane="$(do_split "$pane_id" "$dir" "$cwd")" || exit 1
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
  *) echo "usage: herdr-pane.sh check | split [--pane <ID>] [--dir right|down] | spawn --name N --kind K [--pane <ID>] [--dir right|down] [--cwd DIR] [...] | delegate --name N --kind K [--pane <ID>] [--dir right|down] [--cwd DIR] --prompt T [...]" >&2; exit 2;;
esac
