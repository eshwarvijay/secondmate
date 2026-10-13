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
#     anchor line, any continuation lines of its own question (hold.py puts --q verbatim into the
#     ledger, so a multi-line question renders as literal extra lines after its anchor), and its
#     immediately following indented `    - ` batch sub-entries -- exactly as `hold.py open`
#     renders it, nothing else.
#   - stdout on timeout (exit 3): one final cron-friendly `NO-HOLD: ...` status line.
#   - `--task T`: on match, only a hold whose OWN task field equals T exactly (never substring).
#     T is validated against the same charset hold.py's own task-ids use (alphanumeric plus -_,
#     1-128 chars) and rejected early on anything else; it is never routed through eval/sh -c --
#     bin/hold.py is invoked as a plain argv command. An EXPLICITLY supplied empty value
#     (`--task=`, `--task ""` -- e.g. a dispatcher variable that expanded to nothing) is NOT
#     the same as omitting the flag: it fails the 1-128 charset and is rejected with exit 2,
#     never silently treated as "match any open hold".
#   - `hold.py open`'s `WARNING: N malformed line(s) ...` corruption lines are never a match:
#     each is forwarded verbatim to THIS script's own stderr, and polling continues.
#   - A --task filter matching zero holds while other holds are open is just the ordinary
#     no-match case: the same timeout/exit-3 path, nothing special.
#   - Signals during the wait: SIGTERM -> exit 143, SIGINT -> exit 130 (both distinct from
#     timeout's exit 3). POSIX force-ignores SIGINT for backgrounded commands when job control
#     is off, and a signal ignored on shell entry cannot be trapped -- so a dispatcher's
#     `hold-watch.sh ... &` would silently lose the INT contract (SIGTERM is unaffected: it is
#     never force-ignored). The INT-trap install at the top is then a silent no-op, which
#     `trap -p INT` reflects as EMPTY (a successfully installed trap always lists -- verified
#     live in foreground, backgrounded-no-job-control, and backgrounded-job-control modes). That
#     empty listing is the self-heal's detection (near the bottom, see "SIGINT self-heal"):
#     the instance execs a python that resets the disposition to default and execs this script
#     back -- same pid/argv/env/fds, so the caller's `kill $!` still targets this process and
#     the documented INT -> 130 then works. The interpreter is resolved FIRST through a
#     bounded, group-tracked child so the exec never goes through a PATH wrapper script; a
#     TERM/INT landing anywhere in the heal reaps the whole tree, never orphaning children.
#     Prefer SIGTERM to stop a running instance anyway -- it needs none of this.
#   - The deadline is an absolute wall-clock instant (not a decrementing counter), so a slow poll
#     never steals time from later ticks; sleeps are plain `sleep` (never `read -t`, which races
#     stdin under cron), clamped to the remaining budget so the script never lingers past the
#     deadline. EACH `hold.py open` invocation is itself bounded by the remaining budget (with a
#     1s floor so even --timeout 0 gets one real poll; then TERM and, after a 1s grace, KILL), so
#     a hung/slow single poll can never push the runtime meaningfully past --timeout.
#   - --interval/--timeout accept zero-padded digit strings ("08" is the value it visually is,
#     base-10 -- never bash's octal-literal arithmetic, which used to exit 1 undocumented),
#     capped at 31536000 seconds (one year) so every accepted value is a duration any `sleep`
#     actually honors -- an absurd value is rejected early with exit 2 instead of reaching the
#     loop, where it would otherwise fail every poll/sleep forever with no documented exit.
#   - Exit 2: usage/validation error (bad --task charset, non-numeric/out-of-range numerics,
#     unusable TMPDIR, ...).

set -u

# Anything the script may have in flight, tracked so the TERM/INT traps below can reap ALL of
# it: the inter-poll sleep, a poll in flight plus its killer, a child's whole process GROUP
# (set only when a child was spawned under `set -m` -- a PATH interpreter may be a wrapper
# script with its OWN children, and killing just the wrapper pid would orphan them), and the
# poll's scratch file. Traps go up HERE, before anything that can spawn a child, so no window
# exists in which a signal could leak one.
SLEEP_PID="" POLL_PID="" POLL_KILLER="" POLL_GROUP="" POLL_OUT=""
on_signal() {  # distinct from timeout's exit 3; kill anything in flight so nothing lingers
  [ -n "$POLL_GROUP" ] && kill -TERM -- "-$POLL_GROUP" 2>/dev/null
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  [ -n "$POLL_PID" ] && kill "$POLL_PID" 2>/dev/null
  [ -n "$POLL_KILLER" ] && kill "$POLL_KILLER" 2>/dev/null
  [ -n "$POLL_OUT" ] && rm -f "$POLL_OUT"
  exit "$1"
}
trap 'on_signal 143' TERM
trap 'on_signal 130' INT   # in a backgrounded (non-job-control) invocation this install is a
                           # silent no-op -- detected and healed near the bottom (SIGINT self-heal)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOLD_PY="$SCRIPT_DIR/hold.py"

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
#   - a matched anchor's immediately following indented `    - ` sub-lines (batch entries) AND
#     any intermediate non-anchor continuation lines belong to it -- hold.py puts --q verbatim
#     into the ledger, so a multi-line question renders as literal extra lines after its anchor,
#     and open's output has no other possible line shape; only the FIRST match wins (a later
#     anchor is never appended to the block);
#   - a WARNING line is never a match: forwarded to stderr, scanning/polling continues;
#   - anything else (before the first match) is ignored.
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
        if [[ "$line" =~ $ANCHOR_RE ]]; then
          in_block=0
          if [ "$matched_once" -eq 0 ]; then
            task="${BASH_REMATCH[1]}"
            if [ -z "$filter" ] || [ "$task" = "$filter" ]; then
              block+="$line"$'\n'
              in_block=1
              matched_once=1
            fi
          fi
        elif [ "$in_block" -eq 1 ]; then
          # not an anchor, sub-entry, or WARNING: the only remaining line shape is a continuation
          # of the MATCHED hold's own multi-line question text -- keep it in the block, never end it
          block+="$line"$'\n'
        fi
        ;;
    esac
  done
  MATCH_BLOCK="${block%$'\n'}"
  [ -n "$MATCH_BLOCK" ]
}

# run_bounded <outfile> <budget-secs> <grouped 0|1> <argv...> -- run argv with stdout to
# <outfile>, bounded by the budget: a killer subshell sleeps the budget, then TERMs the child
# (KILL after a 1s grace). If <grouped> is 1, the CALLER spawns this under `set -m` so the child
# becomes its own process-group leader; POLL_GROUP then records it so on_signal reaps the
# child's ENTIRE tree -- a PATH interpreter may be a wrapper script with its own children, and
# a bare pid-kill of the wrapper would orphan them. The killer's inner sleep is a tracked
# child the subshell's own EXIT/TERM traps kill, and the subshell's fds are /dev/null, so
# nothing outlives this call (round-4's no-linger fix, hoisted here so the SIGINT self-heal
# can reuse the exact same machinery).
run_bounded() {
  local ofile="$1" budget="$2" grouped="$3"; shift 3
  local rc=0
  "$@" >"$ofile" 2>/dev/null &
  POLL_PID=$!
  if [ "$grouped" -eq 1 ]; then POLL_GROUP="$POLL_PID"; else POLL_GROUP=""; fi
  (
    tpid=""
    trap '[ -n "${tpid:-}" ] && kill "$tpid" 2>/dev/null' EXIT
    trap '[ -n "${tpid:-}" ] && kill "$tpid" 2>/dev/null; exit' TERM
    sleep "$budget" &
    tpid=$!
    wait "$tpid"
    kill -TERM "$POLL_PID" 2>/dev/null
    sleep 1
    kill -KILL "$POLL_PID" 2>/dev/null
  ) >/dev/null 2>&1 &
  POLL_KILLER=$!
  wait "$POLL_PID"; rc=$?
  POLL_PID=""
  kill "$POLL_KILLER" 2>/dev/null
  wait "$POLL_KILLER" 2>/dev/null
  POLL_KILLER=""
  return "$rc"
}

# poll_once <outfile> <budget-secs> -- one `hold.py open`, bounded by the REMAINING time budget
# (not the full --interval), so a hung/slow hold.py invocation can never push the script
# meaningfully past its --timeout deadline. Returns hold.py's exit status (143 when the budget
# killed it). hold.py's stderr is suppressed: its "(no open decisions)" noise stays out of the
# cron log, and its stdout WARNING lines still reach match_block for stderr forwarding.
poll_once() {
  run_bounded "$1" "$2" 0 python3 "$HOLD_PY" open
}

# watch -- the polling loop. Polls immediately (a hold that is already open is found without
# waiting), then every --interval seconds until the absolute wall-clock deadline elapses. Every
# poll is itself bounded by the remaining budget, and the inter-poll sleep is clamped to the
# remaining budget too, so the runtime never meaningfully exceeds --timeout.
watch() {
  local polls=0 deadline now budget sleep_for pfile
  pfile="$(mktemp "${TMPDIR:-/tmp}/hold-watch-poll.XXXXXX")" \
    || { echo "hold-watch: cannot create the poll scratch file (bad TMPDIR=${TMPDIR:-/tmp}?); refusing to watch blind" >&2; exit 2; }
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
  local hid bid ofile err out rc now elapsed wpid kpid long ok128
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

  # multi-line question (round-5 finding 1): hold.py renders an embedded newline in --q as a
  # literal continuation line after its own anchor; the matched block must KEEP it (and still
  # reach its batch sub-entries), never end at the continuation, and a later anchor must stay
  # excluded -- and a SKIPPED multi-line hold's continuation must not leak into another block
  fixml="$t/fix.multi"
  cat >"$fixml" <<'EOF'
[eee55555] (task-multi) first line
second line of the question
    - sub-m (checked_sha=sha-m) sub-m: verdict=pass findings=0 files=0 lenses=none
[fff66666] (task-next) unrelated
EOF
  wantml='[eee55555] (task-multi) first line
second line of the question
    - sub-m (checked_sha=sha-m) sub-m: verdict=pass findings=0 files=0 lenses=none'
  match_block "" <"$fixml" 2>/dev/null || bad "any-filter: a multi-line-question hold must match"
  [ "$MATCH_BLOCK" = "$wantml" ] \
    || bad "multi-line question: the continuation line and the batch sub-entries must stay in the block -- got: $MATCH_BLOCK"
  match_block "task-multi" <"$fixml" 2>/dev/null || bad "--task must match a multi-line-question hold"
  [ "$MATCH_BLOCK" = "$wantml" ] || bad "multi-line block must be identical under a --task filter"
  match_block "task-next" <"$fixml" 2>/dev/null \
    || bad "--task must still match a LATER anchor that follows a multi-line hold"
  [ "$MATCH_BLOCK" = "[fff66666] (task-next) unrelated" ] \
    || bad "a skipped multi-line hold's continuation must not leak into another block -- got: $MATCH_BLOCK"

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

  # a real multi-line --q round-trip (round-5 finding 1): hold.py puts --q verbatim into the
  # ledger, so open renders the anchor across lines; the watcher must report the FULL block
  mlid="$(SM_HOLD_LEDGER="$ledger" python3 "$HOLD_PY" hold --task rt-multi --q $'line one\nline two' --sha cc 2>/dev/null)" \
    || bad "scratch multi-line hold creation failed"
  rw "$ledger" 0 --task rt-multi --timeout 0
  want_rt="[$mlid] (rt-multi) line one"$'\n'"line two"
  [ "$(cat "$ofile")" = "$want_rt" ] \
    || bad "multi-line question round-trip must print the block with its continuation line -- got: $(cat "$ofile")"

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
  # The watcher runs foreground here, so its INT trap installs and the SIGINT self-heal (which
  # keys on `trap -p INT` being empty) does not fire -- the shim intercepts ONLY the poll
  # interpreter. (The heal's own coverage is the backgrounded SIGINT test below.)
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

  # explicitly-supplied EMPTY --task (round-3 bug 1): not the same as omitting the flag --
  # with the unrelated batch-1 hold still open, both forms must be a loud early exit 2 and
  # must never print that hold as if it were a match
  rc=0; out="$(SM_HOLD_LEDGER="$ledger" "$0" --task= --timeout 0 2>/dev/null)" || rc=$?
  [ "$rc" -eq 2 ] || bad "explicitly empty --task= must be rejected with exit 2, got $rc"
  [ -z "$out" ] || bad "explicitly empty --task= must not print any hold as a match, got: $out"
  rc=0; SM_HOLD_LEDGER="$ledger" "$0" --task "" --timeout 0 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || bad "explicitly empty --task '' (space form) must exit 2, got $rc"

  # absurd --interval/--timeout magnitudes (round-3 bug 2): every accepted value must be a
  # duration `sleep` actually honors -- reject above the 1-year cap here, never loop on
  # failing polls/sleeps forever (validated BEFORE any polling, so these are instant)
  rc=0; "$0" --interval 999999999999999999 --timeout 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || bad "an absurd --interval must be rejected with exit 2, got $rc"
  rc=0; "$0" --timeout 999999999999999999 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || bad "an absurd --timeout must be rejected with exit 2 (no unbounded failing loop), got $rc"
  rw "$ledger" 0 --interval 31536000 --timeout 0   # exactly the cap: accepted, instant first-poll match
  rw "$ledger" 0 --timeout 31536000   # the cap as a TIMEOUT must be ACCEPTED too (the batch hold
  # matches on poll 1, so this costs zero wait) -- guards against a future off-by-one that wrongly
  # rejects the documented maximum timeout

  # stdout captured through a PIPE (round-4 regression): the poll-killer's inner sleep must
  # never linger holding the caller's pipe -- a piping dispatcher must see EOF as soon as the
  # watcher exits (an orphaned `sleep $budget` used to wedge $(...) for up to --timeout)
  now="$(date +%s)"
  out="$(SM_HOLD_LEDGER="$ledger" "$0" --timeout 30 --interval 1 2>/dev/null)" \
    || bad "pipe-capture run should exit 0 on the first-poll match"
  elapsed=$(( $(date +%s) - now ))
  [ "$elapsed" -le 10 ] || bad "a piping dispatcher must not wait on lingering killer sleeps, took ${elapsed}s"
  grep -qF "[$bid] (batch-1) merge batch?" <<<"$out" || bad "pipe-capture run must print the matched block"
  sleep 0.3   # nothing of this invocation may remain: the killer cleans up after itself
  # deliberately ps(1), not pgrep: POSIX ps is guaranteed on the minimal systems pgrep is not,
  # and a missing pgrep would silently weaken this assertion
  # shellcheck disable=SC2009
  if ps -ax -o command= 2>/dev/null | grep -F -- "hold-watch.sh --timeout 30 --interval 1" | grep -qv grep; then
    bad "the poll-killer (or its inner sleep) must not outlive the watcher run"
  fi

  rc=0; "$0" --timeout 31536001 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || bad "--timeout one second above the 1-year cap must exit 2, got $rc"
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

  # mid-heal TERM (round-5 finding 2): a slow PATH interpreter wrapper must not leak its own
  # children when a TERM lands mid-resolution. The heal resolves the interpreter inside a
  # bounded child in its OWN process group, so on_signal reaps the wrapper's whole tree; the
  # exec then goes to the resolved interpreter directly, never through the wrapper.
  shim2="$t/shim2"; mkdir -p "$shim2"
  printf '#!/bin/sh\nsleep 1.6\nexec "%s" "$@"\n' "$realpy" >"$shim2/python3"
  chmod +x "$shim2/python3"
  SM_HOLD_LEDGER="$empty" PATH="$shim2:$PATH" "$0" --interval 30 --timeout 3600 >"$t/heal.out" 2>"$t/heal.err" &
  wpid=$!
  sleep 0.7   # mid-resolution: the wrapper is inside its `sleep 1.6` inside OUR tracked child
  kill -TERM "$wpid" 2>/dev/null
  wait "$wpid"; rc=$?
  [ "$rc" -eq 143 ] || bad "a TERM during the SIGINT self-heal must exit 143, got $rc"
  sleep 0.4   # an un-reaped wrapper child would show up here, orphaned (ppid 1) but still alive
  if ps -ax -o ppid=,command= 2>/dev/null | awk '$1==1 && $2=="sleep" && $3=="1.6" {f=1} END {exit !f}'; then
    bad "a TERM during the self-heal orphaned the interpreter wrapper's child"
  fi

  # broken TMPDIR (round-5 finding 3): the poll scratch file must fail LOUDLY (exit 2), and the
  # SIGINT self-heal must degrade loudly too -- never silently skip (round 4's mktemp-based
  # probe silently defeated the heal exactly when TMPDIR was broken)
  rc=0; TMPDIR="$t/no-such-tmp" "$0" --timeout 0 >"/dev/null" 2>"$t/tmpdir.err" || rc=$?
  [ "$rc" -eq 2 ] || bad "a broken TMPDIR must fail loudly with exit 2, got $rc"
  grep -q "cannot create the poll scratch file" "$t/tmpdir.err" \
    || bad "a broken TMPDIR must print a loud, explicit error"
  TMPDIR="$t/no-such-tmp" SM_HOLD_LEDGER="$empty" "$0" --interval 30 --timeout 3600 >"$t/healb.out" 2>"$t/healb.err" &
  wpid=$!
  sleep 0.5   # enough for the loud fallback heal + the healed instance's own loud pfile exit 2
  kill -TERM "$wpid" 2>/dev/null
  wait "$wpid"; rc=$?
  [ "$rc" -eq 2 ] || bad "a backgrounded broken-TMPDIR watcher must still reach the loud exit 2, got $rc"
  grep -q "self-heal" "$t/healb.err" \
    || bad "a broken TMPDIR must not silently skip the SIGINT self-heal (loud note expected)"

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
(the INT trap install is a silent no-op, which `trap -p INT` shows as empty), resolves the real
interpreter through a bounded, group-tracked child, and execs it to reset the disposition.
Zero-padded --interval/--timeout digit strings are accepted as base-10, capped
at 31536000 seconds (one year). An explicitly supplied empty --task (`--task=`) is rejected
with exit 2 -- it is not the same as omitting the flag.
EOF
}

# ------------------------------------------------------------------ arg parsing
TASK="" TASK_GIVEN=0 INTERVAL=30 TIMEOUT=1800 SELFCHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --task)        [ $# -ge 2 ] || { echo "hold-watch: $1 requires a value" >&2; exit 2; }; TASK="$2"; TASK_GIVEN=1; shift 2 ;;
    --task=*)      TASK="${1#--task=}"; TASK_GIVEN=1; shift ;;
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

# validate BEFORE any polling, so a bad invocation fails fast with a clear error.
# TASK_GIVEN distinguishes "flag never supplied" (TASK empty = the documented default: match
# any open hold) from "flag supplied with an empty value" (`--task=`, `--task ""`): the latter
# must be a LOUD early error -- a dispatcher's accidental empty-variable expansion must never
# silently behave like no filter and false-positive on an unrelated hold.
if [ "$TASK_GIVEN" -eq 1 ] && ! [[ "$TASK" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  echo "hold-watch: invalid --task '$TASK' (task-ids are alphanumeric plus -_, 1-128 chars --" \
       "the same charset hold.py's own task-ids use; an empty explicitly-supplied value is" \
       "not a valid task-id and is not the same as omitting --task)" >&2
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
# cap at one year: far beyond any sane watch, and small enough that every accepted value is a
# duration every sleep implementation actually honors (sleep rejects absurd magnitudes), so a
# bad value dies HERE with a clear exit 2 -- never in the loop as an unbounded failing cycle
[ "$INTERVAL" -le 31536000 ] \
  || { echo "hold-watch: --interval must be <= 31536000 seconds (one year), got '$INTERVAL'" >&2; exit 2; }
[ "$TIMEOUT" -le 31536000 ] \
  || { echo "hold-watch: --timeout must be <= 31536000 seconds (one year), got '$TIMEOUT'" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 \
  || { echo "hold-watch: python3 not found in PATH (needed to run bin/hold.py)" >&2; exit 2; }
[ -f "$HOLD_PY" ] \
  || { echo "hold-watch: $HOLD_PY not found (this script must live next to hold.py in bin/)" >&2; exit 2; }

# ------------------------------------------------------------------ SIGINT self-heal
# POSIX force-ignores SIGINT for backgrounded, non-job-control commands, and a signal ignored
# on shell entry cannot be trapped: the `trap ... INT` at the top of this script was then a
# silent no-op, which `trap -p INT` reflects as EMPTY (a successfully installed trap always
# lists). That empty listing is the detection -- no mktemp, no self-delivered signal, nothing
# that can silently misreport when TMPDIR is broken (round 4's mktemp probe silently skipped
# the heal exactly when it was needed). When INT was force-ignored, only a runtime sigaction
# can undo it, so this instance execs a python that resets the disposition to default and then
# execs this script back: same pid, argv, environment, and fds, so the caller's `kill $!` still
# targets THIS process and the documented INT -> 130 works from then on. The re-run instance
# installs the INT trap successfully (disposition now default), finds `trap -p INT` non-empty,
# and does not heal again -- no loop.
#
# The exec itself must not leak: a PATH `python3` can be a wrapper SCRIPT that spawns its own
# children (pyenv/conda activation shims, etc.), and a TERM/INT landing mid-resolution used to
# kill only the wrapper, orphaning those children. So the real interpreter is resolved FIRST:
# a bounded child in its own process GROUP runs PATH-python3 (wrapper included -- the wrapper's
# children die with the group) just to print its own sys.executable; a signal during that run
# reaps the whole tree via POLL_GROUP (on_signal, top of script). Then the exec goes to the
# RESOLVED interpreter directly, never through the wrapper -- real interpreters spawn no
# children, so a TERM/INT in the exec window dies cleanly by kernel default (143/130), no
# orphan possible. Degraded corners are LOUD, never silent: unusable TMPDIR or a hung/broken
# interpreter each print a stderr note and fall back to the direct PATH exec (round-3
# behavior), where only a pathological wrapper could leak.
if [ -z "$(trap -p INT)" ] && command -v python3 >/dev/null 2>&1; then
  realpy=""
  pf_file="$(mktemp "${TMPDIR:-/tmp}/hold-watch-heal.XXXXXX" 2>/dev/null)" || pf_file=""
  if [ -n "$pf_file" ]; then
    POLL_OUT="$pf_file"
    set -m   # make the resolution child its own process-group leader so on_signal reaps its tree
    run_bounded "$pf_file" 30 1 python3 -c 'import sys; print(sys.executable)' || true
    set +m
    realpy="$(head -n 1 "$pf_file" 2>/dev/null)"
    rm -f "$pf_file"
    POLL_OUT=""
    [ -n "$realpy" ] && [ -x "$realpy" ] \
      || printf 'hold-watch: could not resolve the real python3 for the SIGINT self-heal (slow or broken interpreter in PATH?); falling back to a direct PATH exec\n' >&2
  else
    printf 'hold-watch: cannot create a scratch file for the SIGINT self-heal (bad TMPDIR=%s?); falling back to a direct interpreter exec\n' "${TMPDIR:-/tmp}" >&2
  fi
  [ -n "$realpy" ] && [ -x "$realpy" ] || realpy="python3"
  exec "$realpy" -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvpe(sys.argv[1], sys.argv[1:], os.environ)' "$0" "$@"
fi

watch
