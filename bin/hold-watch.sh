#!/usr/bin/env bash
# hold-watch.sh -- detection-only watchdog for open human-gate holds.
#
#   bin/hold-watch.sh [--task TASK-ID] [--interval SECONDS] [--timeout SECONDS]
#   bin/hold-watch.sh --selfcheck
#
# An external dispatcher that cannot see the parked herdr pane needs a way to detect an open
# human-gate hold. This script polls `bin/hold.py open` every --interval seconds (default 30)
# until --timeout seconds (default 1800) elapse, then gives up. Purely read-and-report: it never
# answers a hold, never writes to the ledger, never acquires a lock -- hold.py's own reads are
# already unlocked/best-effort, so a transient read mid-write self-heals on the next poll tick.
#
# Contract (line-oriented, cron-friendly):
#   - stdout on match (exit 0): the first matching hold's FULL block -- its `[id] (task) question`
#     anchor line plus its immediately following indented `    - ` batch sub-entries -- exactly as
#     `hold.py open` renders it, nothing else.
#   - stdout on timeout (exit 3): one final cron-friendly `NO-HOLD: ...` status line.
#   - `--task T`: on match, only a hold whose OWN task field equals T exactly (never substring).
#     T is validated against the same charset hold.py's own task-ids use (alphanumeric plus -_,
#     1-128 chars) and rejected early on anything else; it is never routed through eval/sh -c --
#     bin/hold.py is invoked as a plain argv command.
#   - `hold.py open`'s `WARNING: N malformed line(s) ...` corruption lines are never a match:
#     each is forwarded verbatim to THIS script's own stderr, and polling continues.
#   - A --task filter matching zero holds while other holds are open is just the ordinary
#     no-match case: the same timeout/exit-3 path, nothing special.
#   - Signals during the wait: SIGTERM -> exit 143, SIGINT -> exit 130 (both distinct from
#     timeout's exit 3). POSIX force-ignores SIGINT for backgrounded commands when job control
#     is off, and a signal ignored on shell entry cannot be trapped -- so a dispatcher's
#     `hold-watch.sh ... &` would silently lose the INT contract (SIGTERM is unaffected: it is
#     never force-ignored). At startup the script self-probes: a one-shot INT trap plus a
#     self-delivered SIGINT. If the trap fires, SIGINT is already this script's (foreground and
#     job-control invocations) and it starts directly; if nothing consumes the signal, SIGINT
#     was force-ignored on entry, and the script re-execs itself once through python3 to reset
#     that disposition to default (only a runtime sigaction can undo an inherited SIG_IGN;
#     bash alone cannot -- `trap -p` does not even expose it). pid/argv/env/fds are preserved
#     by exec, so the caller and `kill $!` still target the same process. Prefer SIGTERM to
#     stop a running instance anyway -- it is the one signal that never needs this treatment.
#   - The deadline is an absolute wall-clock instant (not a decrementing counter), so a slow poll
#     never steals time from later ticks; sleeps are plain `sleep` (never `read -t`, which races
#     stdin under cron), clamped to the remaining budget so the script never lingers past the
#     deadline. EACH `hold.py open` invocation is itself bounded by the remaining budget (with a
#     1s floor so even --timeout 0 gets one real poll; then TERM and, after a 1s grace, KILL), so
#     a hung/slow single poll can never push the runtime meaningfully past --timeout.
#   - --interval/--timeout accept zero-padded digit strings ("08" is the value it visually is,
#     base-10 -- never bash's octal-literal arithmetic, which used to exit 1 undocumented).
#   - Exit 2: usage/validation error (bad --task charset, non-numeric/out-of-range numerics, ...).

set -u

# SIGINT self-heal (see header). `trap -p` cannot detect the inherited force-ignore (bash does not
# expose it), so detect it with a self-probe: install a one-shot INT trap and self-deliver
# SIGINT. If the trap fires, INT was already ours -- no heal, no extra python3 startup. If
# nothing consumed the signal, INT was force-ignored on entry (a backgrounded, non-job-control
# invocation) and only a runtime sigaction can undo that: re-exec through python3, which resets
# the disposition to default before exec'ing us back (pid/argv/env/fds preserved, so the caller
# and `kill $!` still target this same process). No guard variable is needed: the re-exec'd
# instance probes SIG_DFL, finds it trappable, and does not heal again. The one-shot probe trap
# is simply overwritten by the real INT trap installed further below.
_int_probe="$(mktemp "${TMPDIR:-/tmp}/hold-watch-int-probe.XXXXXX")"
trap 'rm -f "$_int_probe"' INT
kill -INT $$
if [ -e "$_int_probe" ]; then   # nothing consumed the signal: SIGINT was ignored on entry
  rm -f "$_int_probe"
  if command -v python3 >/dev/null 2>&1; then
    exec python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvpe(sys.argv[1], sys.argv[1:], os.environ)' "$0" "$@"
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOLD_PY="$SCRIPT_DIR/hold.py"

SLEEP_PID="" POLL_PID="" POLL_KILLER="" POLL_OUT=""
on_signal() {  # distinct from timeout's exit 3; kill anything in flight so nothing lingers
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  [ -n "$POLL_PID" ] && kill "$POLL_PID" 2>/dev/null
  [ -n "$POLL_KILLER" ] && kill "$POLL_KILLER" 2>/dev/null
  [ -n "$POLL_OUT" ] && rm -f "$POLL_OUT"
  exit "$1"
}
trap 'on_signal 143' TERM
trap 'on_signal 130' INT

# hold.py open's per-hold anchor line: `[id] (task) question...   opts: ...`. The task field is
# the first `)`-closed group; a task-id containing `)` cannot be created through hold.py's own
# task-id charset, so exact equality against a validated --task can never false-positive on one.
ANCHOR_RE='^\[[^]]+\] \(([^)]*)\)'

MATCH_BLOCK=""
# match_block <task-filter|""> -- reads one `hold.py open` output from stdin (file redirect or
# herestring -- never a pipeline, which would run this in a subshell and lose MATCH_BLOCK).
# Structural parse of hold.py open's rendering:
#   - an anchor line is a match candidate; --task is EXACT string equality against the captured
#     task field, never substring; empty filter = any open hold;
#   - a matched anchor's immediately following indented `    - ` sub-lines (batch entries) belong
#     to it; only the FIRST match wins (a later anchor is never appended to the block);
#   - a WARNING line is never a match: forwarded to stderr, scanning/polling continues;
#   - anything else is ignored (not a match candidate).
# Returns 0 with MATCH_BLOCK set to the matched block (no trailing newline), 1 with no match.
match_block() {
  local filter="$1" line="" in_block=0 matched_once=0 task="" block=""
  MATCH_BLOCK=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "WARNING:"*)
        printf '%s\n' "$line" >&2
        ;;
      "    - "*)
        [ "$in_block" -eq 1 ] && block+="$line"$'\n'
        ;;
      *)
        in_block=0
        if [ "$matched_once" -eq 0 ] && [[ "$line" =~ $ANCHOR_RE ]]; then
          task="${BASH_REMATCH[1]}"
          if [ -z "$filter" ] || [ "$task" = "$filter" ]; then
            block+="$line"$'\n'
            in_block=1
            matched_once=1
          fi
        fi
        ;;
    esac
  done
  MATCH_BLOCK="${block%$'\n'}"
  [ -n "$MATCH_BLOCK" ]
}

# poll_once <outfile> <budget-secs> -- one `hold.py open`, bounded by the REMAINING time budget
# (not the full --interval), so a hung/slow hold.py invocation can never push the script
# meaningfully past its --timeout deadline. The bound is a backgrounded killer subshell: if the
# poll finishes early, the killer is TERM-killed before its own `kill` can ever run; if the poll
# hangs, it gets TERM and, after a 1s grace, KILL. Returns hold.py's exit status (143 when the
# budget killed it). hold.py's stderr is suppressed: its "(no open decisions)" noise stays out of
# the cron log, and its stdout WARNING lines still reach match_block for stderr forwarding.
poll_once() {
  local ofile="$1" budget="$2" rc=0
  python3 "$HOLD_PY" open >"$ofile" 2>/dev/null &
  POLL_PID=$!
  ( sleep "$budget"; kill -TERM "$POLL_PID" 2>/dev/null; sleep 1; kill -KILL "$POLL_PID" 2>/dev/null ) &
  POLL_KILLER=$!
  wait "$POLL_PID"; rc=$?
  POLL_PID=""
  kill "$POLL_KILLER" 2>/dev/null
  wait "$POLL_KILLER" 2>/dev/null
  POLL_KILLER=""
  return "$rc"
}

# watch -- the polling loop. Polls immediately (a hold that is already open is found without
# waiting), then every --interval seconds until the absolute wall-clock deadline elapses. Every
# poll is itself bounded by the remaining budget, and the inter-poll sleep is clamped to the
# remaining budget too, so the runtime never meaningfully exceeds --timeout.
watch() {
  local polls=0 deadline now budget sleep_for pfile
  pfile="$(mktemp "${TMPDIR:-/tmp}/hold-watch-poll.XXXXXX")"
  POLL_OUT="$pfile"
  deadline=$(( $(date +%s) + TIMEOUT ))
  while :; do
    polls=$((polls + 1))
    budget=$(( deadline - $(date +%s) ))
    [ "$budget" -lt 1 ] && budget=1  # floor: even --timeout 0 gets one real (bounded) poll
    if ! poll_once "$pfile" "$budget"; then
      printf 'hold-watch: hold.py open exited nonzero on poll %d; retrying next tick\n' "$polls" >&2
    fi
    if match_block "$TASK" <"$pfile"; then
      printf '%s\n' "$MATCH_BLOCK"
      rm -f "$pfile"
      exit 0
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      printf 'NO-HOLD: no open hold matching task=%s after %ss (%d polls)\n' "${TASK:-any}" "$TIMEOUT" "$polls"
      rm -f "$pfile"
      exit 3
    fi
    sleep_for=$(( deadline - now ))
    [ "$sleep_for" -gt "$INTERVAL" ] && sleep_for="$INTERVAL"  # never sleep past the deadline
    sleep "$sleep_for" &
    SLEEP_PID=$!
    wait "$SLEEP_PID"   # interruptible by the TERM/INT traps; plain sleep never races stdin
    SLEEP_PID=""
  done
}

# ------------------------------------------------------------------ --selfcheck
# Asserts THIS script's own matching/parsing contract: fixture tests call the real match_block()
# (the exact function the watch loop calls), round-trips run this script as a real subprocess
# against the real bin/hold.py over a scratch ledger (SM_HOLD_LEDGER override). Slow by design
# (but bounded): every ledger round-trip uses --timeout 0 (one immediate poll, zero sleeps)
# except the 1s deadline-clamp check, the ~2s zero-padded check, the ~1s slow-poll-shim check,
# and the signal checks (0.5s each, run in the REAL dispatcher pattern: backgrounded, no job
# control). No test here answers a hold in the real repo's ledger, writes outside the scratch
# dir, or acquires any lock.
SC_FAILS=0
bad() { printf 'selfcheck FAIL: %s\n' "$*" >&2; SC_FAILS=$((SC_FAILS + 1)); }

selfcheck() {
  local t fix warnonly orphan want1 want2 ledger corrupt empty vfile entries shim realpy
  local hid bid ofile err rc now elapsed wpid kpid long ok128
  t="$(mktemp -d)"
  ofile="$t/rw.out"
  err="$t/rw.err"

  # ---------- fixtures through the REAL match_block ----------
  fix="$t/fix.open"
  cat >"$fix" <<'EOF'
[aaa11111] (task-one) ready to merge?
    - sub-a (checked_sha=sha-a) sub-a: verdict=pass findings=0 files=0 lenses=none
    - sub-b (checked_sha=sha-b) sub-b: verdict=fail findings=2 files=2 lenses=none
[bbb22222] (task-two) ship it?   opts: yes, no
WARNING: 2 malformed line(s) in /scratch/decisions.jsonl — ledger may be corrupt; reconcile manually.
EOF
  want1='[aaa11111] (task-one) ready to merge?
    - sub-a (checked_sha=sha-a) sub-a: verdict=pass findings=0 files=0 lenses=none
    - sub-b (checked_sha=sha-b) sub-b: verdict=fail findings=2 files=2 lenses=none'
  want2='[bbb22222] (task-two) ship it?   opts: yes, no'

  match_block "" <"$fix" 2>"$err" || bad "any-filter: the first open hold must match"
  [ "$MATCH_BLOCK" = "$want1" ] \
    || bad "any-filter block must be anchor + its own sub-lines only, not later holds -- got: $MATCH_BLOCK"
  grep -qF "WARNING: 2 malformed line(s)" "$err" \
    || bad "a WARNING line must be forwarded verbatim to stderr"

  match_block "task-two" <"$fix" 2>/dev/null || bad "exact --task must match its own hold"
  [ "$MATCH_BLOCK" = "$want2" ] \
    || bad "filtered block must render the anchor (incl. opts) exactly as hold.py open did -- got: $MATCH_BLOCK"

  match_block "task-one" <"$fix" 2>/dev/null || bad "exact --task must match its own hold (task-one)"
  [ "$MATCH_BLOCK" = "$want1" ] || bad "task-one block must carry its batch sub-entries"

  match_block "task" <"$fix" 2>/dev/null \
    && bad "--task is exact equality, never substring ('task' must not match 'task-one')"
  match_block "task-on" <"$fix" 2>/dev/null \
    && bad "--task prefix must not match ('task-on' is not 'task-one')"
  [ -z "$MATCH_BLOCK" ] || bad "a no-match must leave MATCH_BLOCK empty"

  warnonly="$t/warn.only"
  printf 'WARNING: 5 malformed line(s) in /x/decisions.jsonl — ledger may be corrupt; reconcile manually.\n' >"$warnonly"
  match_block "" <"$warnonly" 2>/dev/null && bad "a WARNING-only output must never be a match"

  orphan="$t/orphan.only"
  printf '    - orphan (checked_sha=sha-x) orphan: verdict=pass findings=0 files=0 lenses=none\n' >"$orphan"
  match_block "" <"$orphan" 2>/dev/null \
    && bad "an indented sub-line with no anchor is never itself a match candidate"

  # ---------- real round-trips: THIS script as a real subprocess + the REAL bin/hold.py,
  # against a scratch ledger. --timeout 0 = one immediate poll, no real wait. ----------
  rw() {  # rw <ledger> <expected-rc> <args...> ; captures stdout to $ofile, stderr to $err
    local wledger="$1" wrc="$2"; shift 2
    local rc=0
    SM_HOLD_LEDGER="$wledger" "$0" "$@" >"$ofile" 2>"$err" || rc=$?
    [ "$rc" -eq "$wrc" ] || bad "exit $rc (wanted $wrc) from: $0 $*"
  }

  ledger="$t/decisions.jsonl"
  hid="$(SM_HOLD_LEDGER="$ledger" python3 "$HOLD_PY" hold --task rt-task --q "rt question?" --sha abc123 2>/dev/null)" \
    || bad "scratch hold creation failed"

  rw "$ledger" 0 --timeout 0 --interval 1
  [ "$(cat "$ofile")" = "[$hid] (rt-task) rt question?" ] \
    || bad "watch stdout must be the hold's exact rendered anchor line -- got: $(cat "$ofile")"

  rw "$ledger" 0 --task rt-task --timeout 0
  grep -qF "[$hid] (rt-task) rt question?" "$ofile" || bad "--task hit: the block must be surfaced"

  rw "$ledger" 3 --task rt-tas --timeout 0  # substring of an open hold's task: ordinary no-match
  head -n 1 "$ofile" | grep -q '^NO-HOLD:' \
    || bad "timeout must print one NO-HOLD line on stdout -- got: $(cat "$ofile")"

  SM_HOLD_LEDGER="$ledger" python3 "$HOLD_PY" answer "$hid" --a ok --sha abc123 >/dev/null 2>&1 \
    || bad "scratch answer failed"
  rw "$ledger" 3 --timeout 0  # an answered hold is no longer open: ordinary no-match

  # a real consolidated BATCH hold: the matched block must include its per-entry sub-lines
  vfile="$t/v.out"
  printf '```json\n{"verdict":"pass","findings":[]}\n```\n' >"$vfile"
  entries="$t/entries.json"
  printf '[{"task_id":"batch-x","checked_sha":"sha-x","checker_verdict_path":"%s"}]' "$vfile" >"$entries"
  bid="$(SM_HOLD_LEDGER="$ledger" python3 "$HOLD_PY" hold --task batch-1 --q "merge batch?" --entries-file "$entries" 2>/dev/null)" \
    || bad "scratch batch hold creation failed"
  rw "$ledger" 0 --task batch-1 --timeout 0
  [ "$(wc -l <"$ofile")" -eq 2 ] \
    || bad "batch block must be exactly anchor + 1 sub-line -- got $(wc -l <"$ofile") line(s)"
  grep -qF "[$bid] (batch-1) merge batch?" "$ofile" || bad "batch anchor must be surfaced verbatim"
  grep -qF "    - batch-x (checked_sha=sha-x) batch-x: verdict=pass findings=0 files=0 lenses=none" "$ofile" \
    || bad "batch sub-entry line must be surfaced verbatim"

  rw "$ledger" 3 --task batch --timeout 0  # substring of the batch task ('batch' vs 'batch-1'): no-match

  # WARNING forwarding end-to-end via hold.py's real corruption path: corrupt line + open hold
  printf 'not json\n' >>"$ledger"
  rw "$ledger" 0 --task batch-1 --timeout 0
  grep -qF "WARNING: 1 malformed line(s)" "$err" \
    || bad "the watcher must forward hold.py's WARNING line to its own stderr"
  grep -q "WARNING" "$ofile" && bad "a WARNING must never leak to stdout"

  corrupt="$t/corrupt.jsonl"  # corrupt-only ledger: WARNING forwarded, never a match, keep polling
  printf 'garbage\n' >"$corrupt"
  rw "$corrupt" 3 --timeout 0
  grep -qF "WARNING: 1 malformed line(s)" "$err" || bad "corrupt-only ledger: WARNING must still hit stderr"
  grep -q '^NO-HOLD:' "$ofile" || bad "corrupt-only ledger: must time out with a NO-HOLD line"

  rw "$t/nope.jsonl" 3 --timeout 0  # a ledger file that does not exist: ordinary no-match

  # absolute-deadline clamp: must give up after ~1s even with --interval 30 (no full-interval sleep
  # past the deadline), proving the runtime never exceeds --timeout.
  empty="$t/empty.jsonl"; : >"$empty"
  now="$(date +%s)"
  rw "$empty" 3 --interval 30 --timeout 1
  elapsed=$(( $(date +%s) - now ))
  [ "$elapsed" -le 5 ] || bad "--timeout 1 must give up after ~1s even with --interval 30 (took ${elapsed}s)"

  # slow hold.py-open substitute near the deadline (bug-1 class): each poll invocation is itself
  # bounded by the REMAINING budget, so a 5s-hanging poll under --timeout 1 still ends at ~1s.
  # The watcher runs foreground here, so its startup self-probe finds SIGINT already trappable
  # and no self-heal re-exec fires -- the shim intercepts ONLY the poll interpreter. (The
  # heal's own coverage is the backgrounded SIGINT test below.)
  shim="$t/shim"; mkdir -p "$shim"
  realpy="$(command -v python3)"
  printf '#!/bin/sh\nsleep 5\nexec "%s" "$@"\n' "$realpy" >"$shim/python3"
  chmod +x "$shim/python3"
  now="$(date +%s)"
  SM_HOLD_LEDGER="$empty" PATH="$shim:$PATH" "$0" --interval 1 --timeout 1 >"$ofile" 2>"$err"
  rc=$?
  elapsed=$(( $(date +%s) - now ))
  [ "$rc" -eq 3 ] || bad "slow-poll substitute: rc=$rc (wanted 3)"
  [ "$elapsed" -le 3 ] || bad "a hung poll must be bounded by the remaining budget: 1s watch took ${elapsed}s"
  grep -q '^NO-HOLD:' "$ofile" || bad "slow-poll substitute must still end with the NO-HOLD line"

  # ---------- argument validation ----------
  rc=0; "$0" --task 'bad task!' --timeout 0 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || bad "invalid --task charset must be rejected early with exit 2, got $rc"
  rc=0; "$0" --task >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || bad "a valueless --task must exit 2, got $rc"
  long="$(head -c 129 /dev/zero | tr '\0' a)"
  rc=0; "$0" --task "$long" --timeout 0 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || bad "a 129-char --task must be rejected (charset caps at 128), got $rc"
  ok128="$(head -c 128 /dev/zero | tr '\0' a)"
  rw "$empty" 3 --task "$ok128" --timeout 0  # 128 chars: charset-accepted, just no matching hold
  rc=0; "$0" --interval 0 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || bad "--interval 0 must be rejected with exit 2, got $rc"
  rc=0; "$0" --timeout abc >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || bad "non-numeric --timeout must be rejected with exit 2, got $rc"

  # zero-padded numerics (bug-2 class): accepted and base-10-normalized -- "09"/"08" are the
  # values they visually are, never bash octal literals (which used to crash exit 1 mid-watch).
  # The open batch hold matches on the first poll, so this costs zero real wait.
  rw "$ledger" 0 --timeout 09 --interval 08
  now="$(date +%s)"
  rw "$empty" 3 --interval 01 --timeout 02   # live zero-padded run: 1s ticks, 2s deadline
  elapsed=$(( $(date +%s) - now ))
  [ "$elapsed" -le 4 ] || bad "zero-padded live run took ${elapsed}s (budget was 2s)"
  grep -q "after 2s (" "$ofile" || bad "NO-HOLD line must report the normalized timeout (2s) -- got: $(cat "$ofile")"
  rw "$empty" 3 --timeout 00                 # "00" = 0: accepted, one immediate poll
  rc=0; "$0" --bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || bad "an unknown argument must be rejected with exit 2, got $rc"
  rc=0; "$0" --help >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || bad "--help must exit 0, got $rc"

  # ---------- signals during the wait, in the REAL dispatcher pattern: backgrounded, NO job
  # control. bash force-ignores SIGINT for such children (an entry-ignored signal cannot be
  # trapped); the startup self-heal re-exec is what restores the documented exit 130. SIGTERM is
  # never force-ignored, so it is the simplest reliable stop; both are asserted here. ----------
  SM_HOLD_LEDGER="$empty" "$0" --interval 30 --timeout 3600 >"$t/sig.out" 2>/dev/null &
  wpid=$!
  sleep 0.5   # past startup (incl. the one-time self-heal exec) into the signal-interruptible wait
  kill -TERM "$wpid" 2>/dev/null
  wait "$wpid"; rc=$?
  [ "$rc" -eq 143 ] || bad "SIGTERM during the wait must exit 143 (distinct from 3), got $rc"
  SM_HOLD_LEDGER="$empty" "$0" --interval 30 --timeout 3600 >/dev/null 2>&1 &
  wpid=$!
  sleep 0.5
  kill -INT "$wpid" 2>/dev/null
  # bound the wait: if a regression ever re-breaks backgrounded SIGINT, fail fast (the rescue
  # TERM yields 143 != 130) instead of hanging the selfcheck for the child's full 3600s.
  ( sleep 5; kill -TERM "$wpid" 2>/dev/null ) &
  kpid=$!
  wait "$wpid"; rc=$?
  kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
  [ "$rc" -eq 130 ] || bad "SIGINT during the wait must exit 130 (distinct from 3), got $rc"

  rm -rf "$t"
  if [ "$SC_FAILS" -eq 0 ]; then echo ok; exit 0; fi
  printf 'selfcheck: %d failure(s)\n' "$SC_FAILS" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: hold-watch.sh [--task TASK-ID] [--interval SECONDS] [--timeout SECONDS]
       hold-watch.sh --selfcheck

Detection-only watchdog: polls `bin/hold.py open` every --interval seconds (default 30) until
--timeout seconds (default 1800) elapse. On match prints the hold's full rendered block and
exits 0; on timeout prints one NO-HOLD line and exits 3. Never answers a hold, writes to the
ledger, or acquires a lock. WARNING corruption lines go to stderr, never stdout.

Exit codes: 0 hold found; 2 usage/validation error; 3 timeout, no matching open hold;
           130 interrupted (SIGINT); 143 terminated (SIGTERM).

Stopping a running instance: prefer SIGTERM (always honored). SIGINT also works, including for
a backgrounded `hold-watch.sh ... &` invocation: POSIX forces SIGINT ignored for non-job-
control background commands (an ignored signal cannot be trapped), so the script detects that
at startup with a one-shot self-probe and re-execs itself once through python3 to reset the
disposition. Zero-padded --interval/--timeout digit strings are accepted as base-10.
EOF
}

# ------------------------------------------------------------------ arg parsing
TASK="" INTERVAL=30 TIMEOUT=1800 SELFCHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --task)        [ $# -ge 2 ] || { echo "hold-watch: $1 requires a value" >&2; exit 2; }; TASK="$2"; shift 2 ;;
    --task=*)      TASK="${1#--task=}"; shift ;;
    --interval)    [ $# -ge 2 ] || { echo "hold-watch: $1 requires a value" >&2; exit 2; }; INTERVAL="$2"; shift 2 ;;
    --interval=*)  INTERVAL="${1#--interval=}"; shift ;;
    --timeout)     [ $# -ge 2 ] || { echo "hold-watch: $1 requires a value" >&2; exit 2; }; TIMEOUT="$2"; shift 2 ;;
    --timeout=*)   TIMEOUT="${1#--timeout=}"; shift ;;
    --selfcheck)   SELFCHECK=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "hold-watch: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$SELFCHECK" -eq 1 ]; then
  selfcheck
  exit 0  # unreachable: selfcheck always exits
fi

# validate BEFORE any polling, so a bad invocation fails fast with a clear error
if [ -n "$TASK" ] && ! [[ "$TASK" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  echo "hold-watch: invalid --task '$TASK' (task-ids are alphanumeric plus -_, 1-128 chars --" \
       "the same charset hold.py's own task-ids use)" >&2
  exit 2
fi
# digit strings only, zero-padding allowed ("08" is the value it visually is), length-capped
# so the normalized value always fits bash's 64-bit arithmetic without silent wraparound
[[ "$INTERVAL" =~ ^[0-9]{1,18}$ ]] \
  || { echo "hold-watch: --interval must be 1-18 digits (seconds), got '$INTERVAL'" >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[0-9]{1,18}$ ]] \
  || { echo "hold-watch: --timeout must be 1-18 digits (seconds), got '$TIMEOUT'" >&2; exit 2; }
INTERVAL="$((10#$INTERVAL))"   # base-10 normalize: never bash's octal-literal arithmetic
TIMEOUT="$((10#$TIMEOUT))"
[ "$INTERVAL" -ge 1 ] \
  || { echo "hold-watch: --interval must be >= 1 second, got '$INTERVAL'" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 \
  || { echo "hold-watch: python3 not found in PATH (needed to run bin/hold.py)" >&2; exit 2; }
[ -f "$HOLD_PY" ] \
  || { echo "hold-watch: $HOLD_PY not found (this script must live next to hold.py in bin/)" >&2; exit 2; }

watch
