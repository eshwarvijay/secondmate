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
#   - `hold.py open`'s corruption marker -- a line of its EXACT emission shape
#     `WARNING: N malformed line(s) in <ledger> — ledger may be corrupt; reconcile manually.`
#     (quoted from hold.py's source; printed once, after ALL holds, always as the LAST line) --
#     is never a match: it is forwarded verbatim to THIS script's own stderr, and polling
#     continues. A line that merely STARTS with WARNING: is a different matter: inside a
#     matched block it is the hold's own human question text (hold.py renders --q verbatim, no
#     escaping) and stays in the printed block; only a byte-complete corruption shape is
#     position-checked (always-last) before being classified as corruption -- see match_block
#     for the residual, documented last-line ambiguity.
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
#     the script execs a python DRIVER whose first statements install INT->130 / TERM->143
#     handlers and which then execs this script back -- same pid/argv/env/fds, so the caller's
#     `kill $!` still targets this process. The driver is exec'd with `-E -S` from the first
#     executable ABSOLUTE interpreter (homebrew paths before the macOS CLT stub; PATH python3
#     only if no absolute candidate exists), so PYTHONPATH/PYTHONHOME and sitecustomize cannot
#     delay it -- the checker's instrumentation vector is closed. The ONLY remaining sliver,
#     live-measured at ~30-50ms: from this script's first instruction until the exec'd bare
#     interpreter's first sigaction line runs -- a signal arriving in that window is still
#     POSIX-discarded (an entry-ignored signal cannot be observed by ANY image on this pid
#     until something sigactions it). Prefer SIGTERM to stop a running instance anyway -- it
#     needs none of this.
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

# hold.py's own end-of-output corruption marker, quoted verbatim from its source (hold.py's
# `open` branch, the ONLY place it is printed):
#   print(f"WARNING: {_BAD} malformed line(s) in {LEDGER} — ledger may be corrupt; reconcile manually.")
# open emits it once, after ALL holds, always as the LAST line of its output. The shape below
# matches that exact emission family (count + any ledger-path rendering + the fixed em-dash
# suffix, end-anchored); human question text only collides by reproducing the COMPLETE line.
# Round 7 tightened this from round 6's bare `WARNING: N malformed line(s) in ` prefix, which
# a real hold's own question text could begin while continuing as ordinary text (the round-7
# checker repro); an in-block full-shape line is additionally position-checked against the
# corruption marker's always-last emission (match_block's pending logic). The residual,
# documented ambiguity is a question whose FINAL rendered line byte-equals a plausible
# corruption line -- same unresolvable-by-text-alone class as the anchor collision below.
CORRUPT_RE='^WARNING: [0-9]+ malformed line\(s\) in .* — ledger may be corrupt; reconcile manually\.$'

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
#   - a WARNING-prefixed line: inside a matched block it is a continuation of that hold's own
#     question text (hold.py renders --q verbatim -- human text can start with WARNING:) unless
#     it byte-matches hold.py's corruption shape ($CORRUPT_RE), which is corruption noise ANYWHERE
#     (it is only ever printed after all holds); outside a block it is forwarded to stderr;
#   - anything else (before the first match) is ignored.
# ACCEPTED AMBIGUITY (same posture as a task-id containing `)`, on record since round 3): a
# continuation line byte-shaped like an anchor (a question that literally contains
# `[fakehold] (fake-task) text`) is indistinguishable from a real new anchor by text alone --
# hold.py's --q is rendered verbatim with no escaping, so no parser confined to this script's
# scope can tell them apart. Documented behavior: it acts as a block boundary (the matched block
# truncates there and the line is an anchor candidate for a later --task filter) -- the only
# alternative would swallow REAL next anchors.
# Returns 0 with MATCH_BLOCK set to the matched block (no trailing newline), 1 with no match.
match_block() {
  local filter="$1" line="" in_block=0 matched_once=0 task="" block="" pending=""
  MATCH_BLOCK=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_block" -eq 1 ] && [[ "$line" =~ $CORRUPT_RE ]]; then
      # hold.py's corruption line is ALWAYS the last line of open's output (it prints after
      # every hold), so a full-shape line inside the matched block can only be CONFIRMED as
      # corruption at EOF; until then it may still be this hold's own question text (round-7
      # finding A: hold.py renders --q verbatim, so human text can reproduce the whole shape)
      # -- hold it and decide when the next line (or EOF) proves which it is
      if [ -n "$pending" ]; then
        block+="$pending"$'\n'   # a successor line already proved the earlier one was text
      fi
      pending="$line"
      continue
    fi
    if [ -n "$pending" ]; then
      block+="$pending"$'\n'     # anything following it proves it was question text, in order
      pending=""
    fi
    case "$line" in
      "WARNING:"*)
        if [ "$in_block" -eq 1 ]; then
          # WARNING-prefixed but NOT the full corruption shape (that was handled above): the
          # hold's own human question text -- hold.py renders --q verbatim, so text CAN start
          # with WARNING:, and even begin a byte-plausible corruption prefix (round-7 checker
          # repro) as long as the fixed em-dash suffix or the end-anchor is absent
          block+="$line"$'\n'
        else
          printf '%s\n' "$line" >&2
        fi
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
  if [ -n "$pending" ]; then
    # full shape AND the stream's very last line: exactly hold.py's corruption-marker position
    # -- treated as corruption noise (RESIDUAL DOCUMENTED AMBIGUITY, same class as the anchor
    # collision: a question whose final rendered line byte-equals a plausible corruption line is
    # indistinguishable; only changing hold.py's rendering could split them)
    printf '%s\n' "$pending" >&2
    pending=""
  fi
  MATCH_BLOCK="${block%$'\n'}"
  [ -n "$MATCH_BLOCK" ]
}

# run_bounded <outfile> <budget-secs> <argv...> -- run argv with stdout to <outfile>, bounded by
# the budget: a killer subshell sleeps the budget, then TERM-KILLs the child's whole PROCESS
# GROUP (KILL after a 1s grace). The child is spawned under `set -m` so it is its own
# process-group leader: a PATH interpreter may be a wrapper script with its OWN children, and a
# bare pid-kill of the wrapper would orphan them -- the group reaps the whole tree on every path
# (early signal via on_signal, budget expiry via the killer). The killer's inner sleep is a
# tracked child the subshell's own EXIT/TERM traps kill, and the subshell's fds are /dev/null,
# so nothing outlives this call (round-4's no-linger fix).
run_bounded() {
  local ofile="$1" budget="$2"; shift 2
  local rc=0
  set -m
  "$@" >"$ofile" 2>/dev/null &
  POLL_PID=$!
  POLL_GROUP="$POLL_PID"
  set +m
  (
    tpid=""
    trap '[ -n "${tpid:-}" ] && kill "$tpid" 2>/dev/null' EXIT
    trap '[ -n "${tpid:-}" ] && kill "$tpid" 2>/dev/null; exit' TERM
    sleep "$budget" &
    tpid=$!
    wait "$tpid"
    kill -TERM -- "-$POLL_PID" 2>/dev/null
    sleep 1
    kill -KILL -- "-$POLL_PID" 2>/dev/null
  ) >/dev/null 2>&1 &
  POLL_KILLER=$!
  wait "$POLL_PID"; rc=$?
  POLL_PID=""
  POLL_GROUP=""
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
  run_bounded "$1" "$2" python3 "$HOLD_PY" open
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
# dir, or acquires any lock — and that isolation is ENFORCED, not merely documented:
# --selfcheck refuses to run with an inherited SM_HOLD_LEDGER (exit 4) and asserts its
# round-trip ledger lives inside its own throwaway scratch dir (exit 4 otherwise).
SC_FAILS=0
bad() { printf 'selfcheck FAIL: %s\n' "$*" >&2; SC_FAILS=$((SC_FAILS + 1)); }

selfcheck() {
  local t fix warnonly orphan want1 want2 ledger corrupt empty vfile entries shim realpy
  local hid bid ofile err out rc now elapsed wpid kpid long ok128
  # Structural isolation guard (round-8 finding C): --selfcheck may create, answer,
  # and edit holds ONLY inside its own throwaway scratch dir. An inherited
  # SM_HOLD_LEDGER pointing anywhere else is refused outright, so the read-only
  # invariant (never answer holds, never edit ledgers) is ENFORCED for every
  # ledger outside selfcheck's own scratch dir -- not merely documented above.
  if [ -n "${SM_HOLD_LEDGER:-}" ]; then
    printf 'selfcheck FAIL: refusing to run with an inherited SM_HOLD_LEDGER (%s) -- selfcheck exercises its round-trips only inside its own throwaway scratch dir\n' "$SM_HOLD_LEDGER" >&2
    exit 4
  fi
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

  # WARNING-shaped question continuation (round-6 finding 1 + round-7 finding A): inside a
  # matched block a line that merely starts with WARNING: -- including the round-7 checker's
  # byte-plausible corruption PREFIX continued as ordinary text -- is the hold's own question
  # text; only hold.py's EXACT emission shape (fixed em-dash suffix, end-anchored) is a
  # corruption candidate, and an in-block full-shape line is position-checked (the real marker
  # is always open's LAST line): full-shape + NOT last = provably question text; full-shape +
  # last = corruption (the residual documented ambiguity). Fixture ordered like real open
  # output: corruption marker last.
  fixw="$t/fix.warnq"
  cat >"$fixw" <<'EOF'
[aaa11111] (task-w) question start
WARNING: this line is my own question text, not corruption
WARNING: 42 malformed line(s) in this is human question text
    - sub-w (checked_sha=sha-w) sub-w: verdict=pass findings=0 files=0 lenses=none
WARNING: 9 malformed line(s) in /y/decisions.jsonl — ledger may be corrupt; reconcile manually.
[bbb22222] (task-next) next
WARNING: 7 malformed line(s) in /x/decisions.jsonl — ledger may be corrupt; reconcile manually.
EOF
  wantw='[aaa11111] (task-w) question start
WARNING: this line is my own question text, not corruption
WARNING: 42 malformed line(s) in this is human question text
    - sub-w (checked_sha=sha-w) sub-w: verdict=pass findings=0 files=0 lenses=none
WARNING: 9 malformed line(s) in /y/decisions.jsonl — ledger may be corrupt; reconcile manually.'
  match_block "" <"$fixw" 2>"$err" || bad "any-filter: a WARNING-continuation hold must match"
  [ "$MATCH_BLOCK" = "$wantw" ] \
    || bad "plausible-prefix and NOT-last full-shape lines must stay in the block (only shape+LAST is corruption) -- got: $MATCH_BLOCK"
  grep -qF "WARNING: 7 malformed line(s) in /x/" "$err" \
    || bad "the last-line corruption marker must still be forwarded to stderr"
  match_block "task-next" <"$fixw" 2>/dev/null \
    || bad "--task must match a later anchor after a WARNING-continuation hold"
  [ "$MATCH_BLOCK" = "[bbb22222] (task-next) next" ] \
    || bad "later anchor after WARNING-continuation -- got: $MATCH_BLOCK"

  # anchor-shaped question continuation (round-6 finding 1, ACCEPTED AMBIGUITY, same posture as
  # a task-id containing `)` on record since round 3): hold.py renders --q verbatim with no
  # escaping, so a continuation line byte-identical to an anchor is indistinguishable from a
  # real new anchor by text alone. Documented behavior: it acts as a block boundary -- the
  # matched block truncates there and the line is an anchor candidate for a later --task filter
  fixa="$t/fix.anchorq"
  cat >"$fixa" <<'EOF'
[aaa11111] (task-a) before the fake anchor
[fake-hold] (fake-task) still question text
[bbb22222] (task-next) next
EOF
  match_block "" <"$fixa" 2>/dev/null || bad "any-filter must still match before a fake-anchor continuation"
  [ "$MATCH_BLOCK" = "[aaa11111] (task-a) before the fake anchor" ] \
    || bad "documented ambiguity behavior: the block must truncate at a byte-anchor-shaped continuation -- got: $MATCH_BLOCK"
  match_block "task-next" <"$fixa" 2>/dev/null \
    || bad "a --task filter must still reach a real anchor after a fake-anchor line"
  [ "$MATCH_BLOCK" = "[bbb22222] (task-next) next" ] \
    || bad "real anchor after a fake-anchor continuation -- got: $MATCH_BLOCK"

  # ---------- real round-trips: THIS script as a real subprocess + the REAL bin/hold.py,
  # against a scratch ledger. --timeout 0 = one immediate poll, no real wait. ----------
  rw() {  # rw <ledger> <expected-rc> <args...> ; captures stdout to $ofile, stderr to $err
    local wledger="$1" wrc="$2"; shift 2
    local rc=0
    SM_HOLD_LEDGER="$wledger" "$0" "$@" >"$ofile" 2>"$err" || rc=$?
    [ "$rc" -eq "$wrc" ] || bad "exit $rc (wanted $wrc) from: $0 $*"
  }

  # mkhold <hold.py hold args...> -> sets MK_ID/MK_TOK from hold.py's real two-line `hold` stdout
  # (id, then "token: TOK") -- never a reimplementation of that shape, just reading it like any
  # real caller would, so $ledger-scoped hold creation below still exercises the genuine CLI output.
  mkhold() {
    local out
    out="$(SM_HOLD_LEDGER="$ledger" python3 "$HOLD_PY" hold "$@" 2>/dev/null)" || return 1
    MK_ID="$(printf '%s\n' "$out" | sed -n '1p')"
    MK_TOK="$(printf '%s\n' "$out" | sed -n '2p')"
    MK_TOK="${MK_TOK#token: }"
  }

  ledger="$t/decisions.jsonl"
  # Structural isolation guard, part 2: the round-trip ledger must live inside
  # this selfcheck's own throwaway dir; anything else is a hard failure.
  case "$ledger" in
    "$t"/*) ;;
    *) printf 'selfcheck FAIL: scratch ledger escaped its scratch dir: %s\n' "$ledger" >&2; exit 4 ;;
  esac
  mkhold --task rt-task --q "rt question?" --sha abc123 || bad "scratch hold creation failed"
  hid="$MK_ID"; hidtok="$MK_TOK"

  rw "$ledger" 0 --timeout 0 --interval 1
  [ "$(cat "$ofile")" = "[$hid] (rt-task) rt question?   token: $hidtok" ] \
    || bad "watch stdout must be the hold's exact rendered anchor line -- got: $(cat "$ofile")"

  rw "$ledger" 0 --task rt-task --timeout 0
  grep -qF "[$hid] (rt-task) rt question?" "$ofile" || bad "--task hit: the block must be surfaced"

  rw "$ledger" 3 --task rt-tas --timeout 0  # substring of an open hold's task: ordinary no-match
  head -n 1 "$ofile" | grep -q '^NO-HOLD:' \
    || bad "timeout must print one NO-HOLD line on stdout -- got: $(cat "$ofile")"

  SM_HOLD_LEDGER="$ledger" python3 "$HOLD_PY" answer "$hid" --token "$hidtok" --a ok --sha abc123 >/dev/null 2>&1 \
    || bad "scratch answer failed"
  rw "$ledger" 3 --timeout 0  # an answered hold is no longer open: ordinary no-match

  # a real consolidated BATCH hold: the matched block must include its per-entry sub-lines
  vfile="$t/v.out"
  printf '```json\n{"verdict":"pass","findings":[]}\n```\n' >"$vfile"
  entries="$t/entries.json"
  printf '[{"task_id":"batch-x","checked_sha":"sha-x","checker_verdict_path":"%s"}]' "$vfile" >"$entries"
  mkhold --task batch-1 --q "merge batch?" --entries-file "$entries" || bad "scratch batch hold creation failed"
  bid="$MK_ID"
  rw "$ledger" 0 --task batch-1 --timeout 0
  [ "$(wc -l <"$ofile")" -eq 2 ] \
    || bad "batch block must be exactly anchor + 1 sub-line -- got $(wc -l <"$ofile") line(s)"
  grep -qF "[$bid] (batch-1) merge batch?" "$ofile" || bad "batch anchor must be surfaced verbatim"
  grep -qF "    - batch-x (checked_sha=sha-x) batch-x: verdict=pass findings=0 files=0 lenses=none" "$ofile" \
    || bad "batch sub-entry line must be surfaced verbatim"

  # a real multi-line --q round-trip (round-5 finding 1): hold.py puts --q verbatim into the
  # ledger, so open renders the anchor across lines; the watcher must report the FULL block
  mkhold --task rt-multi --q $'line one\nline two' --sha cc || bad "scratch multi-line hold creation failed"
  mlid="$MK_ID"; mlidtok="$MK_TOK"
  rw "$ledger" 0 --task rt-multi --timeout 0
  want_rt="[$mlid] (rt-multi) line one"$'\n'"line two   token: $mlidtok"
  [ "$(cat "$ofile")" = "$want_rt" ] \
    || bad "multi-line question round-trip must print the block with its continuation line -- got: $(cat "$ofile")"

  # a real WARNING-shaped question continuation round-trip (round-6 finding 1): the hold's own
  # question text that starts a line with WARNING: must stay in the printed block, never be
  # reclassified as fake corruption noise on stderr
  mkhold --task warnq --q $'real question\nWARNING: is this a corruption line?' --sha dd \
    || bad "scratch WARNING-question hold creation failed"
  wqid="$MK_ID"; wqidtok="$MK_TOK"
  rw "$ledger" 0 --task warnq --timeout 0
  want_wq="[$wqid] (warnq) real question"$'\n'"WARNING: is this a corruption line?   token: $wqidtok"
  [ "$(cat "$ofile")" = "$want_wq" ] \
    || bad "WARNING-shaped continuation round-trip: the full block must include the WARNING question line -- got: $(cat "$ofile")"
  grep -q "is this a corruption line" "$err" \
    && bad "the WARNING-shaped question line must NOT be routed to stderr as fake corruption"

  # a real anchor-shaped question continuation round-trip (round-6 finding 1, ACCEPTED
  # AMBIGUITY): asserted end-to-end per the documented truncation behavior. hold.py's token suffix
  # lands on the LAST physical line it prints (the fake-anchor line itself, here), which this
  # truncation discards anyway -- the retained "before the fake" line is unaffected by it.
  mkhold --task anchorq --q $'before the fake\n[fake-hold] (fake-task) still question text' --sha ee \
    || bad "scratch anchor-question hold creation failed"
  aqid="$MK_ID"
  rw "$ledger" 0 --task anchorq --timeout 0
  [ "$(cat "$ofile")" = "[$aqid] (anchorq) before the fake" ] \
    || bad "anchor-shaped continuation round-trip: documented truncation behavior -- got: $(cat "$ofile")"

  # round-7 finding A, the checker's exact repro: question text that begins a byte-plausible
  # corruption PREFIX but continues as ordinary text must stay in the printed block (round 6's
  # loose prefix shape misrouted it; only the full emission shape incl. the fixed em-dash
  # suffix, end-anchored, is a corruption candidate)
  mkhold --task warning-shape --q $'question begins\nWARNING: 42 malformed line(s) in this is human question text' --sha ff \
    || bad "scratch warning-shape hold creation failed"
  wsid="$MK_ID"; wsidtok="$MK_TOK"
  rw "$ledger" 0 --task warning-shape --timeout 0
  want_ws="[$wsid] (warning-shape) question begins"$'\n'"WARNING: 42 malformed line(s) in this is human question text   token: $wsidtok"
  [ "$(cat "$ofile")" = "$want_ws" ] \
    || bad "warning-shape round-trip: the plausible-prefix question line must stay in the block -- got: $(cat "$ofile")"
  grep -q "this is human question text" "$err" \
    && bad "the plausible-prefix question line must NOT be routed to stderr as fake corruption"

  # round-7 position rule: a FULL-shape line that is NOT open's last line is provably question
  # text (hold.py's corruption marker is always the LAST line)
  mkhold --task fullshape --q $'before\nWARNING: 42 malformed line(s) in whatever — ledger may be corrupt; reconcile manually.\nafter' --sha gg \
    || bad "scratch fullshape hold creation failed"
  fsid="$MK_ID"; fsidtok="$MK_TOK"
  rw "$ledger" 0 --task fullshape --timeout 0
  want_fs="[$fsid] (fullshape) before"$'\n'"WARNING: 42 malformed line(s) in whatever — ledger may be corrupt; reconcile manually."$'\n'"after   token: $fsidtok"
  [ "$(cat "$ofile")" = "$want_fs" ] \
    || bad "full-shape + NOT-last: position proves question text -- got: $(cat "$ofile")"

  # round-7's RESIDUAL DOCUMENTED AMBIGUITY (full shape AND the very last line of the output,
  # byte-identical to the real corruption marker) is RESOLVED by the token suffix added in this
  # change: hold.py's own corruption marker (printed separately by `open`, never carrying a token)
  # stays byte-exact, but every hold's own anchor/continuation text now always ends in
  # "   token: ..." -- so a question whose last line reproduces the corruption shape no longer
  # byte-matches CORRUPT_RE's end anchor, and is unambiguously kept as question text.
  mkhold --task lastline --q $'before\nWARNING: 42 malformed line(s) in whatever — ledger may be corrupt; reconcile manually.' --sha hh \
    || bad "scratch lastline hold creation failed"
  lsid="$MK_ID"; lsidtok="$MK_TOK"
  rw "$ledger" 0 --task lastline --timeout 0
  want_ls="[$lsid] (lastline) before"$'\n'"WARNING: 42 malformed line(s) in whatever — ledger may be corrupt; reconcile manually.   token: $lsidtok"
  # the exact-match stdout assertion above is the full proof here: a misclassified-as-corruption
  # line would have truncated stdout to just "[$lsid] (lastline) before" and forwarded the WARNING
  # line to stderr instead -- no separate $err check is needed (and one keyed on this same literal
  # substring would be confused by the UNRELATED skipped "fullshape" hold's own non-last WARNING
  # line, which legitimately still hits stderr while its block is skipped by this --task filter).
  [ "$(cat "$ofile")" = "$want_ls" ] \
    || bad "lastline: the token suffix breaks the byte-match with the corruption marker, so this must stay in the block as question text -- got: $(cat "$ofile")"

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
  sleep 0.4   # the budget-expired poll was TERMed mid-wrapper-sleep: its child must die WITH the
  # poll's process group (round-6 grouped polls), never be orphaned to linger out the shim delay
  if ps -ax -o ppid=,command= 2>/dev/null | awk '$1==1 && $2=="sleep" && $3=="5" {f=1} END {exit !f}'; then
    bad "the budget-expired poll orphaned the interpreter wrapper's child"
  fi

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

  # mid-run TERM with a slow PATH interpreter wrapper (round-5 finding 2 + round-6 grouped
  # polls): the wrapper intercepts every poll; a TERM landing mid-poll must reap the wrapper's
  # WHOLE tree (poll children run as their own process group now), never orphan its `sleep`
  shim2="$t/shim2"; mkdir -p "$shim2"
  printf '#!/bin/sh\nsleep 1.6\nexec "%s" "$@\n' "$realpy" >"$shim2/python3"
  chmod +x "$shim2/python3"
  SM_HOLD_LEDGER="$empty" PATH="$shim2:$PATH" "$0" --interval 30 --timeout 3600 >"$t/heal.out" 2>"$t/heal.err" &
  wpid=$!
  sleep 0.7   # mid-poll: the wrapper is inside its `sleep 1.6` inside our tracked group child
  kill -TERM "$wpid" 2>/dev/null
  wait "$wpid"; rc=$?
  [ "$rc" -eq 143 ] || bad "a TERM mid-run with a wrapper interpreter must exit 143, got $rc"
  sleep 0.4   # an un-reaped wrapper child would show up here, orphaned (ppid 1) but still alive
  if ps -ax -o ppid=,command= 2>/dev/null | awk '$1==1 && $2=="sleep" && $3=="1.6" {f=1} END {exit !f}'; then
    bad "a TERM mid-run orphaned the interpreter wrapper's child"
  fi

  # INT through the ENTIRE self-heal window (round-6 finding 2, the checker's exact repro): with
  # a slow PATH wrapper the round-5 design stayed INT-deaf for the wrapper's whole resolution;
  # the heal now execs an ABSOLUTE interpreter (bypassing the wrapper) whose first statements
  # arm INT->130, so kill -INT $! lands on a healed, INT-trapped watcher almost immediately
  # -- and reaps the wrapper's tree as it goes
  if [ -x /usr/local/bin/python3 ] || [ -x /opt/homebrew/bin/python3 ] || [ -x /usr/bin/python3 ]; then
    shim3="$t/shim3"; mkdir -p "$shim3"
    printf '#!/bin/sh\nsleep 2\nexec "%s" "$@"\n' "$realpy" >"$shim3/python3"
    chmod +x "$shim3/python3"
    SM_HOLD_LEDGER="$empty" PATH="$shim3:$PATH" "$0" --interval 30 --timeout 3600 >"$t/int.out" 2>/dev/null &
    wpid=$!
    sleep 0.6   # the round-5 design was INT-deaf here for the wrapper's whole startup+resolution
    kill -INT "$wpid" 2>/dev/null
    # bound the wait: a regression that re-breaks the window fails fast with 143 != 130
    ( sleep 5; kill -TERM "$wpid" 2>/dev/null ) &
    kpid=$!
    wait "$wpid"; rc=$?
    kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
    [ "$rc" -eq 130 ] || bad "kill -INT during the self-heal window must exit 130 (got $rc)"
    if ps -ax -o ppid=,command= 2>/dev/null | awk '$1==1 && $2=="sleep" && $3=="2" {f=1} END {exit !f}'; then
      bad "INT during the heal window orphaned the wrapper's child"
    fi
  else
    echo "  (skipped: no absolute python3 for the fast-heal path -- documented PATH-fallback sliver)"
  fi

  # round-7 finding B, the checker's exact repro vector: an instrumented interpreter
  # (PYTHONPATH + a sleeping sitecustomize) used to delay the heal's PRETEST child for the
  # whole sleep, leaving the preflight INT-deaf. The pretest is gone and the driver is exec'd
  # with -E -S (no PYTHONPATH, no site machinery), so the instrumentation cannot widen the
  # deaf window: INT mid-heal still lands on the armed driver / healed watcher
  if [ -x /usr/local/bin/python3 ] || [ -x /opt/homebrew/bin/python3 ] || [ -x /usr/bin/python3 ]; then
    sited="$t/pysite"; mkdir -p "$sited"
    printf 'import time\ntime.sleep(2)\n' >"$sited/sitecustomize.py"
    PYTHONPATH="$sited" SM_HOLD_LEDGER="$empty" "$0" --interval 30 --timeout 3600 >"$t/pyint.out" 2>/dev/null &
    wpid=$!
    sleep 0.6   # round 6's design sat in the instrumented-pretest INT-deaf window here
    kill -INT "$wpid" 2>/dev/null
    ( sleep 5; kill -TERM "$wpid" 2>/dev/null ) &
    kpid=$!
    wait "$wpid"; rc=$?
    kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
    [ "$rc" -eq 130 ] || bad "an instrumented interpreter (sitecustomize) must not delay the INT heal (got $rc)"
  fi

  # heal-argv survival (round-7 bug found by my own mutation harness): the heal's exec used
  # the post-parse "$@" (empty), so every backgrounded -- i.e. INT-ignored, the REAL
  # dispatcher pattern -- invocation healed into a bare watcher: --task lost (match-any)
  # and --timeout lost (default 1800s). These runs background the watcher (the heal fires)
  # and assert the args SURVIVE it; a lost --timeout would hang into the rescue TERM.
  SM_HOLD_LEDGER="$ledger" "$0" --task lastline --timeout 30 >"$t/argv.out" 2>"$t/argv.err" &
  wpid=$!
  ( sleep 10; kill -TERM "$wpid" 2>/dev/null ) &
  kpid=$!
  wait "$wpid"; rc=$?
  kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
  [ "$rc" -eq 0 ] || bad "heal-argv survival: --task lastline must still match after the heal (rc=$rc)"
  grep -qF "(lastline) before" "$t/argv.out" \
    || bad "heal-argv survival: --task was lost across the heal -- got: $(cat "$t/argv.out")"
  grep -q "(batch-1) merge batch?" "$t/argv.out" \
    && bad "heal-argv survival: the watcher matched the FIRST open hold (match-any: args lost)"
  SM_HOLD_LEDGER="$empty" "$0" --timeout 2 >"$t/argv2.out" 2>/dev/null &
  wpid=$!
  ( sleep 10; kill -TERM "$wpid" 2>/dev/null ) &
  kpid=$!
  wait "$wpid"; rc=$?
  kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
  [ "$rc" -eq 3 ] || bad "heal-argv survival: --timeout 2 must survive the heal (rc=$rc; lost => 1800s default => rescue)"
  grep -q '^NO-HOLD:' "$t/argv2.out" || bad "heal-argv survival: expected a NO-HOLD timeout line"

  # broken TMPDIR (round-5 finding 3): the poll scratch file must fail LOUDLY (exit 2), and the
  # SIGINT self-heal must degrade loudly too -- never silently skip (round 4's mktemp-based
  # probe silently defeated the heal exactly when TMPDIR was broken)
  rc=0; TMPDIR="$t/no-such-tmp" "$0" --timeout 0 >"/dev/null" 2>"$t/tmpdir.err" || rc=$?
  [ "$rc" -eq 2 ] || bad "a broken TMPDIR must fail loudly with exit 2, got $rc"
  grep -q "cannot create the poll scratch file" "$t/tmpdir.err" \
    || bad "a broken TMPDIR must print a loud, explicit error"
  TMPDIR="$t/no-such-tmp" SM_HOLD_LEDGER="$empty" "$0" --interval 30 --timeout 3600 >"$t/healb.out" 2>"$t/healb.err" &
  wpid=$!
  sleep 0.5   # the heal itself is TMPDIR-free now; the healed instance dies loudly at watch start
  kill -TERM "$wpid" 2>/dev/null
  wait "$wpid"; rc=$?
  [ "$rc" -eq 2 ] || bad "a backgrounded broken-TMPDIR watcher must still reach the loud exit 2, got $rc"
  grep -q "cannot create the poll scratch file" "$t/healb.err" \
    || bad "the healed watcher's loud poll-scratch failure must reach stderr (the heal itself is now TMPDIR-free, so the loud path IS the pfile error)"

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
# ORIG_ARGS snapshots argv BEFORE the parse loop below consumes it with `shift`: the SIGINT
# self-heal's exec at the bottom re-runs this script and must pass the ORIGINAL argv through
# (round-7 bug, found by my own mutation harness running the selfcheck as an async child:
# the heal used the post-parse "$@" -- empty -- so every INT-ignored (real dispatcher
# pattern) invocation healed into a BARE watcher: --task lost (match-any false positives) and
# --timeout lost (default 1800s hangs). The guard expansion keeps empty-arg runs safe under
# set -u on older bashes.)
ORIG_ARGS=("$@")
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
# lists). That empty listing is the detection. When INT was force-ignored, only a runtime
# sigaction on THIS pid can undo it, so this instance execs a python DRIVER whose FIRST
# statements install INT->130 / TERM->143 handlers and which then execs this script back:
# same pid/argv/env/fds, and from the driver's first line on, the caller's `kill -INT $!` ->
# 130 holds. The re-run script instance installs the INT trap successfully (disposition now
# default), finds `trap -p INT` non-empty, and does not heal again -- no loop.
#
# Round 7 removed the round-6 preflight PRETEST entirely: the pretest child (a full
# `python -c pass` startup, before the driver's handlers existed) was itself INT-deaf for its
# whole wall-clock, and a dispatcher-environment instrumented interpreter (PYTHONPATH + a
# sleeping sitecustomize -- the checker's repro) made that window multi-second. Now the exec
# IS the health test: the driver runs `-E -S`, so PYTHONPATH/PYTHONHOME and the site machinery
# (sitecustomize) are skipped -- the deaf window is exactly ONE bare interpreter startup to
# its first sigaction line, immune to the instrumentation vector. The first EXECUTABLE
# candidate is used blind (homebrew paths before the macOS CLT stub); if a candidate's image
# loads but is broken (e.g. /usr/bin/python3 without Command Line Tools), the watcher dies
# with that interpreter's own loud stderr error and exit code -- the documented trade-off
# against reintroducing an unbounded deaf pretest. With no absolute candidate at all, PATH
# python3 is exec'd and the deaf window then includes that interpreter's own startup.
if [ -z "$(trap -p INT)" ] && command -v python3 >/dev/null 2>&1; then
  driver='import os,signal,sys; signal.signal(signal.SIGINT, lambda *a: sys.exit(130)); signal.signal(signal.SIGTERM, lambda *a: sys.exit(143)); os.execvpe(sys.argv[1], sys.argv[1:], os.environ)'
  for cand in /usr/local/bin/python3 /opt/homebrew/bin/python3 /usr/bin/python3; do
    [ -x "$cand" ] && exec "$cand" -E -S -c "$driver" "$0" "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"
  done
  exec python3 -E -S -c "$driver" "$0" "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"
fi

watch
