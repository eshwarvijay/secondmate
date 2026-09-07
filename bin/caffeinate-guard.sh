#!/usr/bin/env bash
# caffeinate-guard.sh -- prevent macOS sleep during a session's active workwindow
#   caffeinate-guard.sh start
#   caffeinate-guard.sh stop
#
# State: $SM_CAFFEINATE_ROOT (default ~/.secondmate-caffeinate), host-wide.
# Single guard process per session; spawned once when session starts, torn down once when session ends.
# Bounded -t <seconds> ceiling (default 8 hours) as defense-in-depth orphan cleanup.
#
# LIMITATIONS (accepted, not bugs):
# - This is a single host-wide guard. Running multiple independent secondmate-orchestrating
#   sessions concurrently on the same machine is not supported. One session's stop can kill
#   sleep prevention for another session's still-active batch (by design, matching this
#   project's precedent of documenting rather than chasing every possible concurrency edge case).
# - A start call overlapping a concurrent stop call for the same guard is not fully serialized
#   against each other (only start-vs-start is). An adversarially-timed overlap could in theory
#   let stop's cleanup remove a just-written new guard's pidfile, leaving it untracked until its
#   TTL expires. This requires violating the documented call-stop-only-after-all-tasks-are-torn-down
#   contract to reach in practice.
# - The fingerprint check identifies a process by its comm name and start time at spawn time;
#   it assumes 'caffeinate' in PATH resolves to a well-behaved system utility that does not
#   replace its own process image via exec after launch. Defending against an adversarially-
#   substituted PATH entry masquerading as caffeinate is out of scope for this feature.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default: multi-hour ceiling so a bug elsewhere only leaks for hours, not "forever"
DEFAULT_TTL_SECONDS=28800  # 8 hours

# State directory, host-wide
_STATE_ROOT() {
  echo "${SM_CAFFEINATE_ROOT:-$HOME/.secondmate-caffeinate}"
}

# Guard PID file path (fixed, session-scoped, no per-task separation)
_GUARD_PIDFILE() {
  local root="$(_STATE_ROOT)"
  echo "$root/guard.pid"
}

# Validate TTL: must be a positive integer, clamped to ceiling (8 hours)
# Exits 2 if invalid, prints clamped value to stdout otherwise
_validate_ttl() {
  local input="$1"
  # Reject empty
  [ -n "$input" ] || { echo "TTL must be a positive integer (got empty)" >&2; exit 2; }
  # Reject non-digit characters
  if [[ ! "$input" =~ ^[0-9]+$ ]]; then
    echo "TTL must be a positive integer (got: $input)" >&2
    exit 2
  fi
  # Reject absurdly long values (overflow protection) - 6 digits is plenty for seconds
  if [ "${#input}" -gt 6 ]; then
    echo "TTL too large (max 6 digits, got ${#input}): $input" >&2
    exit 2
  fi
  # Reject zero (caffeinate -t 0 exits almost immediately)
  if [ "$input" -eq 0 ]; then
    echo "TTL must be positive (got 0 -- caffeinate exits almost immediately)" >&2
    exit 2
  fi
  # Clamp to ceiling (8 hours / 28800 seconds)
  if [ "$input" -gt "$DEFAULT_TTL_SECONDS" ]; then
    echo "TTL clamped from $input to max $DEFAULT_TTL_SECONDS seconds (8 hours)" >&2
    echo "$DEFAULT_TTL_SECONDS"
    return 0
  fi
  echo "$input"
  return 0
}

# Build fingerprint for a PID: "comm=... lstart=..." snapshot
_build_fingerprint() {
  local pid="$1"
  # Use ps to get comm command and lstart; format as key=value for stable parsing
  local comm lstart
  comm="$(ps -p "$pid" -o comm= 2>/dev/null)" || { echo ""; return; }
  lstart="$(ps -p "$pid" -o lstart= 2>/dev/null)" || { echo ""; return; }
  # Strip trailing whitespace from lstart (ps adds spaces)
  lstart="$(echo "$lstart" | sed 's/[[:space:]]*$//')"
  echo "comm=$comm lstart=$lstart"
}

# Verify PID still exists and matches the stored fingerprint
_verify_pid_fingerprint() {
  local pid="$1"
  local expected_fingerprint="$2"
  # Check if process exists
  [ -n "$pid" ] || { return 1; }
  ps -p "$pid" >/dev/null 2>&1 || { return 1; }
  # Get current fingerprint and compare
  local current_fingerprint
  current_fingerprint="$(_build_fingerprint "$pid")"
  [ -n "$current_fingerprint" ] || { return 1; }
  [ "$current_fingerprint" = "$expected_fingerprint" ]
}

_start() {
  local root="$(_STATE_ROOT)"
  local pf="$(_GUARD_PIDFILE)"
  local claimfile="$root/.start.lock"
  local ttl="$DEFAULT_TTL_SECONDS"

  # Parse --ttl <seconds> argument if provided
  while [ $# -gt 0 ]; do
    case "$1" in
      --ttl)
        [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }
        ttl="$2"
        shift 2
        ;;
      *)
        echo "unknown arg: $1" >&2
        exit 2
        ;;
    esac
  done

  # Validate and clamp TTL
  ttl="$(_validate_ttl "$ttl")" || exit 2

  # Ensure state directory exists
  mkdir -p "$root"
  chmod 700 "$root"

  # SHORT-LOCK: wrap the critical section (check pidfile, maybe spawn, write pidfile)
  # Use bash noclobber (set -C) for atomic O_CREAT|O_EXCL claim acquisition
  # Timeout is brief (~2s) since the critical section itself is tiny
  local claimstart=$SECONDS
  local claimtimeout=2
  while ! ( set -C; echo "$$" > "$claimfile" ) 2>/dev/null; do
    if [ $((SECONDS - claimstart)) -ge $claimtimeout ]; then
      echo "failed to acquire start lock within ${claimtimeout}s" >&2
      exit 1
    fi
    # Claim file exists - check if holder is alive
    if [ -f "$claimfile" ]; then
      local held_pid
      held_pid="$(cat "$claimfile" 2>/dev/null)"
      if [ -n "$held_pid" ] && ps -p "$held_pid" >/dev/null 2>&1; then
        # Holder is still alive - wait and retry
        sleep 0.1
        continue
      fi
      # Holder is dead - stale claim, remove it and retry
      rm -f "$claimfile"
    fi
  done

  # Now holding the claim - run the critical section
  # Idempotent: if guard already exists and is alive with matching fingerprint, no-op
  if [ -f "$pf" ]; then
    local line existing_pid existing_fingerprint
    line="$(head -n1 "$pf" 2>/dev/null)" || line=""
    existing_pid="$(echo "$line" | awk '{print $1}')"
    existing_fingerprint="$(echo "$line" | sed 's/^[^ ]* //')"

    if [ -n "$existing_pid" ] && [ -n "$existing_fingerprint" ]; then
      if _verify_pid_fingerprint "$existing_pid" "$existing_fingerprint"; then
        rm -f "$claimfile"  # Release claim before returning
        echo "guard already active (pid=$existing_pid), no action taken"
        return 0
      fi
    fi
  fi

  # Check if caffeinate is available
  if ! command -v caffeinate >/dev/null 2>&1; then
    echo "WARNING: caffeinate not found in PATH; sleep prevention unavailable on this system" >&2
    # Write a sentinel marking we know caffeinate is missing (keeps idempotent)
    echo "# caffeinate not found" > "$pf"
    rm -f "$claimfile"  # Release claim
    return 0
  fi

  # Spawn caffeinate with bounded TTL (defense-in-depth)
  # -d -i -s: display, idle, screensaver (prevent sleep on all activity)
  # -t <ttl>: bounded ceiling to ensure orphan cleanup if supervisor crashes
  # Redirect stdout/stderr to /dev/null to avoid command substitution hanging
  # (backgrounded child would inherit parent's stdout, blocking until TTL expires)
  caffeinate -d -i -s -t "$ttl" >/dev/null 2>&1 &
  local pid=$!

  # Record PID immediately, before any other step that could fail
  local fingerprint="$(_build_fingerprint "$pid")"
  if [ -z "$fingerprint" ]; then
    echo "ERROR: failed to capture fingerprint for new caffeinate process (pid=$pid)" >&2
    kill "$pid" 2>/dev/null || true
    rm -f "$claimfile"  # Release claim
    return 1
  fi
  echo "$pid $fingerprint" > "$pf"

  rm -f "$claimfile"  # Release claim before returning

  echo "started guard (pid=$pid, ttl=${ttl}s)"
}

_stop() {
  local root="$(_STATE_ROOT)"
  local pf="$(_GUARD_PIDFILE)"

  # Parse arguments strictly - stop takes no arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      *)
        echo "unknown arg: $1" >&2
        exit 2
        ;;
    esac
  done

  # Idempotent: no pidfile -> immediate exit 0, no error
  [ -f "$pf" ] || { echo "no guard found, nothing to stop"; return 0; }

  local line
  line="$(head -n1 "$pf" 2>/dev/null)" || line=""
  local pid="$(echo "$line" | awk '{print $1}')"
  local fingerprint="$(echo "$line" | sed 's/^[^ ]* //')"

  # Check for invalid state
  if [ -z "$pid" ] || [ -z "$fingerprint" ]; then
    rm -f "$pf"
    echo "guard had invalid state (empty pid/fingerprint), cleaned up"
    return 0
  fi

  # Verify identity BEFORE signaling (PID may have been recycled)
  if ! _verify_pid_fingerprint "$pid" "$fingerprint"; then
    rm -f "$pf"
    echo "guard (pid=$pid) is no longer active, cleaned up state"
    return 0
  fi

  # Send SIGTERM first
  kill -TERM "$pid" 2>/dev/null || true

  # Poll until process is actually gone (bounded loop, escalate if needed)
  local polls=0
  local max_polls=20  # 0.5s intervals -> 10s total before escalating
  while [ $polls -lt $max_polls ]; do
    if ps -p "$pid" >/dev/null 2>&1; then
      polls=$((polls + 1))
      sleep 0.25
    else
      break
    fi
  done

  # If still alive after polling, escalate to SIGKILL
  if ps -p "$pid" >/dev/null 2>&1; then
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.1
  fi

  # Final verification: confirm process is gone
  if ps -p "$pid" >/dev/null 2>&1; then
    echo "WARNING: failed to terminate caffeinate process (pid=$pid)" >&2
    rm -f "$pf"
    return 1
  fi

  # Clean up state
  rm -f "$pf"

  echo "stopped guard (pid=$pid verified dead)"
}

if [ "${1:-}" = "--selfcheck" ]; then
  t="$(mktemp -d)"; fails=0; export SM_CAFFEINATE_ROOT="$t"; root="$t"
  # Capture current PATH before any tests modify it
  _CG_ORIG_PATH="$PATH"

  _cg() {
    local script_path="$SCRIPT_DIR/caffeinate-guard.sh"
    # Use the PATH that was passed to _cg (e.g., PATH=/tmp/empty_bin _cg start)
    # which overrides the default original PATH
    SM_CAFFEINATE_ROOT="$t" PATH="$PATH" /bin/bash "$script_path" "$@"
  }

  _guard_pidfile() {
    local root="$SM_CAFFEINATE_ROOT"
    echo "$root/guard.pid"
  }

  # Finding #1: idempotent double-start (should reuse same process)
  _cg start >/dev/null; pid1="$(head -n1 "$(_guard_pidfile)" | awk '{print $1}')"
  _cg start >/dev/null; pid2="$(head -n1 "$(_guard_pidfile)" | awk '{print $1}')"
  [ "$pid1" = "$pid2" ] || { echo "FAIL: double-start produces different PIDs"; fails=1; }
  ps -p "$pid1" >/dev/null 2>&1 || { echo "FAIL: guard process not running after double-start"; fails=1; }
  _cg stop >/dev/null

  # Finding #2: idempotent double-stop (should exit 0, no error)
  _cg start >/dev/null; _cg stop >/dev/null; _cg stop || { echo "FAIL: double-stop exited non-zero"; fails=1; }

  # Finding #3: stop on no prior start (should be instant exit 0)
  rm -f "$root/guard.pid"
  start_time=$SECONDS
  _cg stop >/dev/null || { echo "FAIL: stop on no-prior-start exited non-zero"; fails=1; }
  elapsed=$((SECONDS - start_time))
  [ $elapsed -le 2 ] || { echo "FAIL: stop on no-prior-start took ${elapsed}s (should be <2s)"; fails=1; }

  # Finding #4: identity mismatch protects a live unrelated process
  # Start a live unrelated process and put its PID into guard.pid with wrong fingerprint
  sleep 100 &
  unrelated_pid=$!
  # Store wrong fingerprint (simulate mismatch)
  echo "$unrelated_pid wrong=fingerprint" > "$root/guard.pid"
  _cg stop >/dev/null || { echo "FAIL: stop on mismatched fingerprint exited non-zero"; fails=1; }
  # The unrelated process should still be alive
  ps -p "$unrelated_pid" >/dev/null 2>&1 || { echo "FAIL: unrelated process was incorrectly killed"; fails=1; }
  kill "$unrelated_pid" 2>/dev/null || true
  rm -f "$root/guard.pid"

  # Finding #5: oversized TTL is rejected or clamped
  rc=0; _cg start --ttl 1234567890123456789012345678901234567890 >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: 40-digit TTL not rejected (rc=$rc)"; fails=1; }

  # Finding #6: custom TTL value is actually applied (not overwritten by default)
  _cg start --ttl 45 >/dev/null
  guard_pid="$(head -n1 "$(_guard_pidfile)" | awk '{print $1}')"
  actual_ttl="$(ps -p "$guard_pid" -o args= 2>/dev/null | grep -o -- '-t [0-9]*' | awk '{print $2}' || true)"
  [ "$actual_ttl" = "45" ] || { echo "FAIL: custom TTL 45 not applied (actual=$actual_ttl)"; fails=1; }
  _cg stop >/dev/null

  # Finding #7: stop with unrecognized argument must exit 2 (strict arg validation)
  # Start a guard first (stop needs a pidfile to check for unknown args, but we verify it rejects them)
  _cg start >/dev/null
  rc=0; _cg stop --task legacy >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: stop with --task legacy should exit 2 (rc=$rc)"; fails=1; }
  _cg stop >/dev/null

  # Finding #7: command substitution does not hang (backgrounded child stdout/stderr handled)
  # TIME BOUNDED: must complete in <3s (TTL is 8 hours, so <3s proves no hang)
  rm -f "$root/guard.pid"
  start_time=$SECONDS
  result=$(_cg start)  # Use actual command substitution like a real caller
  elapsed=$((SECONDS - start_time))
  [ $elapsed -le 3 ] || { echo "FAIL: start via command substitution took ${elapsed}s (should be <3s)"; fails=1; }
  guard_pid="$(head -n1 "$(_guard_pidfile)" | awk '{print $1}')"
  ps -p "$guard_pid" >/dev/null 2>&1 || { echo "FAIL: guard process not actually running after start"; fails=1; }
  _cg stop >/dev/null

  # Finding #8: command substitution does not hang (backgrounded child stdout/stderr handled)
  # TIME BOUNDED: must complete in <3s (TTL is 8 hours, so <3s proves no hang)
  rm -f "$root/guard.pid"
  start_time=$SECONDS
  result=$(_cg start)  # Use actual command substitution like a real caller
  elapsed=$((SECONDS - start_time))
  [ $elapsed -le 3 ] || { echo "FAIL: start via command substitution took ${elapsed}s (should be <3s)"; fails=1; }
  guard_pid="$(head -n1 "$(_guard_pidfile)" | awk '{print $1}')"
  ps -p "$guard_pid" >/dev/null 2>&1 || { echo "FAIL: guard process not actually running after start"; fails=1; }
  _cg stop >/dev/null

  # Finding #9: concurrent starts produce exactly ONE guard (no orphan processes)
  # Run 20 parallel starts (simulating multiple tasks calling start redundantly)
  before_pids="$(ps aux | grep '[c]affeinate -d -i -s' | awk '{print $2}' | sort || true)"
  for i in $(seq 1 20); do
    _cg start >/dev/null &
  done
  wait  # Wait for all parallel starts to complete
  # Verify exactly ONE new guard process was created by this test
  after_pids="$(ps aux | grep '[c]affeinate -d -i -s' | awk '{print $2}' | sort || true)"
  new_pids="$(comm -13 <(echo "$before_pids") <(echo "$after_pids"))"
  num_new="$(echo "$new_pids" | grep -c . || true)"
  [ "$num_new" = "1" ] || { echo "FAIL: expected exactly 1 new guard process from concurrent starts, found $num_new"; fails=1; }
  # Verify the guard.pid has exactly one entry
  num_entries=$(wc -l < "$root/guard.pid" | tr -d ' ')
  [ "$num_entries" = "1" ] || { echo "FAIL: guard.pid has $num_entries lines, expected 1"; fails=1; }
  _cg stop >/dev/null

  # Finding #10: caffeinate missing degrades gracefully (warn, exit 0)
  # Build an allowlist PATH containing ONLY the coreutils this script needs, deliberately
  # excluding caffeinate -- excluding a whole real directory (e.g. /usr/bin) breaks the
  # script's OWN dependencies on macOS, since caffeinate lives alongside dirname/awk/etc there.
  fake_bin="$(mktemp -d)"
  for tool in bash dirname awk sed head ps kill mkdir chmod rm sleep cat wc grep tr seq env; do
    tool_path="$(command -v "$tool" 2>/dev/null)"
    [ -n "$tool_path" ] && ln -s "$tool_path" "$fake_bin/$tool"
  done
  rm -f "$root/guard.pid"
  PATH="$fake_bin" bash "$SCRIPT_DIR/caffeinate-guard.sh" start > /tmp/cg10-out.txt 2>&1
  rc10=$?
  [ "$rc10" = 0 ] || { echo "FAIL: start with missing binary should exit 0 (rc=$rc10)"; fails=1; }
  grep -q 'caffeinate not found' /tmp/cg10-out.txt || { echo "FAIL: should warn caffeinate not found"; fails=1; }
  [ -f "$root/guard.pid" ] || { echo "FAIL: should write sentinel"; fails=1; }
  head -n1 "$root/guard.pid" | grep -q '# caffeinate not found' || { echo "FAIL: sentinel content wrong"; fails=1; }
  rc10=0
  PATH="$fake_bin" bash "$SCRIPT_DIR/caffeinate-guard.sh" start > /tmp/cg10-out.txt 2>&1 || rc10=$?
  [ "$rc10" = 0 ] || { echo "FAIL: first start with missing binary should exit 0"; fails=1; }
  grep -q 'caffeinate not found' /tmp/cg10-out.txt || { echo "FAIL: should warn caffeinate not found"; fails=1; }
  [ -f "$root/guard.pid" ] || { echo "FAIL: should write sentinel"; fails=1; }
  head -n1 "$root/guard.pid" | grep -q '# caffeinate not found' || { echo "FAIL: sentinel content wrong"; fails=1; }
  rc10=0
  PATH="$fake_bin" bash "$SCRIPT_DIR/caffeinate-guard.sh" start > /tmp/cg10-out2.txt 2>&1 || rc10=$?
  [ "$rc10" = 0 ] || { echo "FAIL: second start with missing binary should exit 0"; fails=1; }
  rm -f "$root/guard.pid" /tmp/cg10-out.txt /tmp/cg10-out2.txt
  rm -rf "$fake_bin"

  # Finding #10b: fingerprint capture failure path (ps fails after spawn)
  # The _start function spawns caffeinate then immediately calls ps to capture fingerprint.
  # If ps fails at that moment, fingerprint is empty, and we exit 1 with cleanup.
  # Test this by temporarily replacing ps with a command that fails
  fake_ps_bin="$(mktemp -d)"
  for tool in bash dirname awk sed head mkdir chmod rm sleep cat grep tr seq env; do
    tool_path="$(command -v "$tool" 2>/dev/null)"
    [ -n "$tool_path" ] && ln -s "$tool_path" "$fake_ps_bin/$tool"
  done
  # Create fake ps that always exits 1
  cat > "$fake_ps_bin/ps" << 'PS_EOF'
#!/bin/bash
exit 1
PS_EOF
  chmod +x "$fake_ps_bin/ps"
  # Temporarily prepend fake bin to PATH for ps override only
  cg10b_out="$(PATH="${fake_ps_bin}:${PATH}" bash "$SCRIPT_DIR/caffeinate-guard.sh" start 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: start with failing ps should exit 1 (rc=$rc)"; fails=1; }
  [ ! -f "$root/guard.pid" ] || { echo "FAIL: start with failing ps should not write pidfile"; fails=1; }
  # Verify the spawned process was killed (extract PID from error message and check it's dead)
  spawned_pid="$(echo "$cg10b_out" | grep -o 'pid=[0-9]*' | head -1 | grep -o '[0-9]*')"
  if [ -n "$spawned_pid" ]; then
    kill -0 "$spawned_pid" 2>/dev/null && { echo "FAIL: fingerprint failure left orphan caffeinate process (pid=$spawned_pid still alive)"; fails=1; }
  fi
  rm -rf "$fake_ps_bin"

  rm -rf "$t"; [ "$fails" = 0 ] && echo ok; exit "$fails"
fi

# Main command dispatch
cmd="${1:-}"; [ $# -gt 0 ] && shift

case "$cmd" in
  start)
    _start "$@"
    ;;
  stop)
    _stop "$@"
    ;;
  *)
    echo "usage: $0 start | stop | --selfcheck" >&2
    exit 2
    ;;
esac
