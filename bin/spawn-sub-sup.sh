#!/usr/bin/env bash
# spawn-sub-sup.sh -- harness-neutral launcher for ONE fresh headless Claude Code sub-agent-supervisor
# running ONE secondmate task (solo or batch dispatch), reporting completion through
# dispatch-report.py's exit-code contract. It only composes prompts and parses tags -- it never
# duplicates claim-ledger.py / hold.py / merge-sequencer.sh logic, and launches exactly one
# sub-supervisor per invocation (no retry/timeout/watchdog, no multi-task fan-out -- that's the
# top-level dispatcher's job).
#
#   spawn-sub-sup.sh --task-id ID --mode solo|batch [--batch-id ID] [--repo DIR] [--log-dir DIR]
#                     [--prompt-file FILE]
#   spawn-sub-sup.sh --selfcheck
#
# Exit codes (relayed straight from dispatch-report.py, except 5 which is this script's own):
#   0 SM_DONE_MERGED   1 SM_REFUSED   2 SM_STUCK_NEED_HUMAN (also: batch self-merge violation)
#   3 no tag found     4 SM_READY_UNMERGED
#   5 claude subprocess crashed/was killed -- dispatch-report.py is NEVER invoked on this path
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ID_RE='^[A-Za-z0-9_-]{1,128}$'   # same shape claim-ledger.py's _TASK_ID_RE enforces

validate_id() {
  local label="$1" val="$2"
  if [[ ! "$val" =~ $_ID_RE ]]; then
    echo "invalid --$label '$val' (must match ${_ID_RE})" >&2
    exit 2
  fi
}

# Atomically opens fd 9 for writing to a predictable artifact path (prompt/log/result), failing with
# no fd leaked if ANYTHING already exists there -- regular file or symlink (even dangling), checked by
# the kernel's own O_EXCL at open() time, never a separate stat-then-write step a concurrent attacker
# could win a race against by swapping in a symlink between the check and the write.
exclusive_open() {
  local path="$1" rc
  set -C
  exec 9> "$path"
  rc=$?
  set +C
  return "$rc"
}

# Substitutes {{TASK_ID}}/{{OWNER}}/{{REPO}}/{{MODE}}/{{BATCH_ID}} into a template file's contents.
# batch_id may be "" (solo mode never has one). Prints the rendered prompt to stdout.
render_prompt() {
  local mode="$1" task_id="$2" owner="$3" repo="$4" batch_id="$5" template_file="$6"
  local prompt
  prompt="$(cat "$template_file")"
  prompt="${prompt//\{\{TASK_ID\}\}/$task_id}"
  prompt="${prompt//\{\{OWNER\}\}/$owner}"
  prompt="${prompt//\{\{REPO\}\}/$repo}"
  prompt="${prompt//\{\{MODE\}\}/$mode}"
  if [ -n "$batch_id" ]; then
    prompt="${prompt//\{\{BATCH_ID\}\}/$batch_id}"
  fi
  printf '%s' "$prompt"
}

# Reads an --output-format stream-json --verbose NDJSON log, prints the LAST line's "result" field
# whose "type" is "result". Prints nothing (empty) if no such line exists. Malformed/non-JSON lines
# are skipped silently -- NDJSON streams can interleave non-result events freely. Takes a path
# argument (used by isolated selfcheck tests against a real file), or reads stdin when called with
# no argument (the real end-to-end path: fed the already-captured claude output directly, so this
# never re-opens the log artifact's path from scratch after the fact).
extract_result() {
  python3 -c '
import json, sys
last = None
f = open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin
for line in f:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    if isinstance(obj, dict) and obj.get("type") == "result" and isinstance(obj.get("result"), str):
        last = obj["result"]
if last is not None:
    sys.stdout.write(last)
' "$@"
}

if [ "${1:-}" = "--selfcheck" ]; then
  # Defense in depth: an ambient exported `claude` shell function must never shadow the synthetic
  # stub below (the real fix is `command claude` at the launch site; this just closes the gap for
  # any child "$0" invocation forked from this selfcheck process too).
  unset -f claude 2>/dev/null || true
  fails=0
  t="$(mktemp -d)"

  # --- argv validation ---
  rc=0; "$0" --mode solo >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: missing --task-id ($rc)"; fails=1; }
  rc=0; "$0" --task-id t1 >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: missing --mode ($rc)"; fails=1; }
  rc=0; "$0" --task-id t1 --mode batch >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: batch without --batch-id ($rc)"; fails=1; }
  rc=0; "$0" --task-id t1 --mode solo --batch-id b1 >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: solo with extraneous --batch-id ($rc)"; fails=1; }
  rc=0; "$0" --task-id 'bad id!' --mode solo >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: invalid --task-id shape ($rc)"; fails=1; }
  rc=0; "$0" --task-id t1 --mode batch --batch-id 'bad id!' >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: invalid --batch-id shape ($rc)"; fails=1; }
  rc=0; "$0" --task-id t1 --mode wat >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: unknown --mode ($rc)"; fails=1; }

  # --- template placeholder substitution (solo + batch) ---
  out="$(render_prompt solo T1 sm-T1 /repo/x solo "$SCRIPT_DIR/spawn-sub-sup-prompt-solo.txt")"
  echo "$out" | grep -q 'task-id: T1'   || { echo "FAIL: solo template task-id not substituted"; fails=1; }
  echo "$out" | grep -q 'owner:   sm-T1' || { echo "FAIL: solo template owner not substituted"; fails=1; }
  echo "$out" | grep -q 'repo:    /repo/x' || { echo "FAIL: solo template repo not substituted"; fails=1; }
  echo "$out" | grep -qF '{{' && { echo "FAIL: solo template left an unsubstituted placeholder"; fails=1; }
  out="$(render_prompt batch T2 sm-T2 /repo/y B9 "$SCRIPT_DIR/spawn-sub-sup-prompt-batch.txt")"
  echo "$out" | grep -q 'task-id:  T2'  || { echo "FAIL: batch template task-id not substituted"; fails=1; }
  echo "$out" | grep -q 'batch-id: B9'  || { echo "FAIL: batch template batch-id not substituted"; fails=1; }
  echo "$out" | grep -qF '{{' && { echo "FAIL: batch template left an unsubstituted placeholder"; fails=1; }

  # --- stream-json extraction (isolated, no claude process involved) ---
  log1="$t/r1.log"
  printf '%s\n' \
    '{"type":"system","subtype":"init"}' \
    'not even json' \
    '{"type":"result","result":"first (ignored)"}' \
    '{"type":"assistant","message":{}}' \
    '{"type":"result","result":"SM_DONE_MERGED:abc123"}' \
    > "$log1"
  [ "$(extract_result "$log1")" = "SM_DONE_MERGED:abc123" ] || { echo "FAIL: extract_result did not take the LAST result line"; fails=1; }
  log2="$t/r2.log"
  printf '%s\n' '{"type":"system"}' '{"type":"assistant","message":{}}' > "$log2"
  [ -z "$(extract_result "$log2")" ] || { echo "FAIL: extract_result should be empty when no result line exists"; fails=1; }

  # --- fake claude harness for end-to-end dispatch-report.py integration + the two cross-checks ---
  fakebin="$t/fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
[ -n "${CLAUDE_INVOKED_MARKER:-}" ] && : > "$CLAUDE_INVOKED_MARKER"
if [ -n "${CLAUDE_RECEIVED_PROMPT_FILE:-}" ]; then
  while [ $# -gt 0 ]; do
    if [ "$1" = "-p" ]; then
      printf '%s' "$2" > "$CLAUDE_RECEIVED_PROMPT_FILE"
    fi
    shift
  done
fi
case "${FAKE_CLAUDE_BEHAVIOR:-ok}" in
  crash)
    echo '{"type":"system"}'
    exit 7
    ;;
  no_tag)
    echo '{"type":"system"}'
    echo '{"type":"result","result":"ran clean, nothing taggable here"}'
    ;;
  batch_violation)
    echo '{"type":"system"}'
    printf '%s\n' '{"type":"result","result":"work done\nSM_DONE_MERGED:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}'
    ;;
  claim_token)
    echo '{"type":"system"}'
    printf '%s\n' '{"type":"result","result":"SM_CLAIM_TOKEN:tok-xyz\nSM_READY_UNMERGED:cafef00dcafef00dcafef00dcafef00dcafef00d"}'
    ;;
  slow)
    sleep 1
    echo '{"type":"system"}'
    echo '{"type":"result","result":"SM_DONE_MERGED:5a0105ca5a0105ca5a0105ca5a0105ca5a0105ca"}'
    ;;
  non_string_result)
    echo '{"type":"system"}'
    echo '{"type":"result","result":{"unexpected":"object"}}'
    ;;
  short_sha_done)
    echo '{"type":"system"}'
    echo '{"type":"result","result":"SM_DONE_MERGED:cafef00d"}'
    ;;
  short_sha_ready)
    echo '{"type":"system"}'
    echo '{"type":"result","result":"SM_READY_UNMERGED:deadbeef"}'
    ;;
  known_sha_real)
    echo '{"type":"system"}'
    echo '{"type":"result","result":"SM_DONE_MERGED:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
    ;;
  *)
    echo '{"type":"system"}'
    echo '{"type":"result","result":"SM_DONE_MERGED:cafef00dcafef00dcafef00dcafef00dcafef00d"}'
    ;;
esac
FAKE
  chmod +x "$fakebin/claude"
  repo_dir="$t/repo"; mkdir -p "$repo_dir"

  # 1) ordinary solo success: dispatch-report.py's own exit 0, result relayed, no crash/violation noise.
  log_dir="$t/run1"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=ok "$0" --task-id ok1 --mode solo --repo "$repo_dir" --log-dir "$log_dir" 2>"$t/run1.err")" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: ordinary solo success exit ($rc)"; fails=1; }
  echo "$out" | grep -q 'SM_DONE_MERGED:cafef00dcafef00dcafef00dcafef00dcafef00d' || { echo "FAIL: ordinary solo success did not relay dispatch-report.py output"; fails=1; }

  # 2) crash disambiguation: claude killed/nonzero -> exit 5, stderr banner, dispatch-report.py NEVER run
  #    (no .result file is ever written on this path).
  log_dir="$t/run2"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=crash "$0" --task-id crash1 --mode solo --repo "$repo_dir" --log-dir "$log_dir" 2>"$t/run2.err")" || rc=$?
  [ "$rc" = 5 ] || { echo "FAIL: crashed claude subprocess exit ($rc, want 5)"; fails=1; }
  grep -qi 'crash' "$t/run2.err" || { echo "FAIL: no crash banner on stderr"; fails=1; }
  [ -f "$log_dir/sm-crash1.result" ] && { echo "FAIL: .result file written despite claude crashing"; fails=1; }

  # 3) clean-but-no-tag must NOT be confused with a crash: exit 3, dispatch-report.py's own malformed code.
  log_dir="$t/run3"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=no_tag "$0" --task-id notag1 --mode solo --repo "$repo_dir" --log-dir "$log_dir" 2>"$t/run3.err")" || rc=$?
  [ "$rc" = 3 ] || { echo "FAIL: clean-no-tag exit ($rc, want 3)"; fails=1; }

  # 4) batch self-merge contract violation: a batch-mode run whose final tag is SM_DONE_MERGED (not
  #    SM_READY_UNMERGED) must be caught, logged distinctly, and exit dispatch-report.py's own code 2 --
  #    never 0, never a freshly invented code.
  log_dir="$t/run4"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=batch_violation "$0" --task-id bv1 --mode batch --batch-id bb1 --repo "$repo_dir" --log-dir "$log_dir" 2>"$t/run4.err")" || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: batch self-merge violation exit ($rc, want 2)"; fails=1; }
  grep -qi 'SELF-MERGE' "$t/run4.err" || { echo "FAIL: batch self-merge violation not logged with distinct wording"; fails=1; }
  grep -q 'generic' "$t/run4.err" && { echo "FAIL: batch violation wording looks like a generic stuck message"; fails=1; }

  # 5) the SAME SM_DONE_MERGED tag under solo mode is NOT a violation -- exit stays 0.
  log_dir="$t/run5"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=batch_violation "$0" --task-id sv1 --mode solo --repo "$repo_dir" --log-dir "$log_dir" 2>"$t/run5.err")" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: solo mode with SM_DONE_MERGED should exit 0, not treat it as a violation ($rc)"; fails=1; }

  # 6) SM_CLAIM_TOKEN relay: best-effort, printed when present, never a second source of truth (it is
  #    never consulted for the exit code -- the tag line alone drives that, as case 1 above shows).
  log_dir="$t/run6"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=claim_token "$0" --task-id ct1 --mode solo --repo "$repo_dir" --log-dir "$log_dir" 2>"$t/run6.err")" || rc=$?
  [ "$rc" = 4 ] || { echo "FAIL: claim-token case exit ($rc, want 4 for SM_READY_UNMERGED)"; fails=1; }
  echo "$out" | grep -q 'SM_CLAIM_TOKEN:tok-xyz' || { echo "FAIL: SM_CLAIM_TOKEN not relayed"; fails=1; }

  # 7) --prompt-file overrides the mode's built-in template, same placeholders still substituted.
  custom="$t/custom.txt"; printf 'CUSTOM TEMPLATE task={{TASK_ID}} owner={{OWNER}}\n' > "$custom"
  log_dir="$t/run7"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=ok "$0" --task-id pf1 --mode solo --repo "$repo_dir" --log-dir "$log_dir" --prompt-file "$custom" 2>"$t/run7.err")" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: --prompt-file run exit ($rc)"; fails=1; }
  grep -q 'CUSTOM TEMPLATE task=pf1 owner=sm-pf1' "$log_dir/sm-pf1.prompt" || { echo "FAIL: --prompt-file override not rendered with substituted placeholders"; fails=1; }

  # 7b) an unreadable --prompt-file must stop with a clear config error BEFORE claude ever launches --
  #     never silently proceed with an empty/partial prompt and relay a false success tag.
  unreadable="$t/unreadable.txt"; printf 'should never be read or used\n' > "$unreadable"; chmod 000 "$unreadable"
  claude_marker="$t/claude_invoked_marker"; rm -f "$claude_marker"
  log_dir="$t/run7b"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=ok CLAUDE_INVOKED_MARKER="$claude_marker" "$0" --task-id pfunreadable --mode solo --repo "$repo_dir" --log-dir "$log_dir" --prompt-file "$unreadable" 2>"$t/run7b.err")" || rc=$?
  chmod 644 "$unreadable"
  [ "$rc" = 2 ] || { echo "FAIL: unreadable --prompt-file should exit 2 (got $rc)"; fails=1; }
  grep -qi 'not readable' "$t/run7b.err" || { echo "FAIL: unreadable --prompt-file refusal message missing"; fails=1; }
  [ -f "$claude_marker" ] && { echo "FAIL: claude was invoked despite an unreadable --prompt-file"; fails=1; }

  # 8) symlink refusal: a pre-existing symlink at the .prompt/.log/.result path must be refused, not
  #    followed -- a local attacker pre-creating one must never get the victim file overwritten.
  log_dir="$t/run8"; mkdir -p "$log_dir"
  victim="$t/victim-prompt"; echo SENTINEL > "$victim"
  ln -s "$victim" "$log_dir/sm-symprompt.prompt"
  rc=0; PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=ok "$0" --task-id symprompt --mode solo --repo "$repo_dir" --log-dir "$log_dir" >/dev/null 2>"$t/run8.err" || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: pre-existing symlink at .prompt path should be refused with exit 2 ($rc)"; fails=1; }
  grep -qi 'symlink' "$t/run8.err" || { echo "FAIL: .prompt symlink refusal message missing"; fails=1; }
  [ "$(cat "$victim")" = "SENTINEL" ] || { echo "FAIL: victim file for .prompt symlink was overwritten"; fails=1; }

  log_dir="$t/run9"; mkdir -p "$log_dir"
  victim2="$t/victim-log"; echo SENTINEL2 > "$victim2"
  ln -s "$victim2" "$log_dir/sm-symlog.log"
  rc=0; PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=ok "$0" --task-id symlog --mode solo --repo "$repo_dir" --log-dir "$log_dir" >/dev/null 2>"$t/run9.err" || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: pre-existing symlink at .log path should be refused with exit 2 ($rc)"; fails=1; }
  grep -qi 'symlink' "$t/run9.err" || { echo "FAIL: .log symlink refusal message missing"; fails=1; }
  [ "$(cat "$victim2")" = "SENTINEL2" ] || { echo "FAIL: victim file for .log symlink was overwritten"; fails=1; }

  log_dir="$t/run10"; mkdir -p "$log_dir"
  victim3="$t/victim-result"; echo SENTINEL3 > "$victim3"
  ln -s "$victim3" "$log_dir/sm-symresult.result"
  rc=0; PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=ok "$0" --task-id symresult --mode solo --repo "$repo_dir" --log-dir "$log_dir" >/dev/null 2>"$t/run10.err" || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: pre-existing symlink at .result path should be refused with exit 2 ($rc)"; fails=1; }
  grep -qi 'symlink' "$t/run10.err" || { echo "FAIL: .result symlink refusal message missing"; fails=1; }
  [ "$(cat "$victim3")" = "SENTINEL3" ] || { echo "FAIL: victim file for .result symlink was overwritten"; fails=1; }

  # 8b) exclusive_open's OWN atomicity, distinct from tests 8-10 above: those only prove "refuses a
  #     symlink that already existed before the process started" -- a check-then-open implementation
  #     (`[ -e "$path" ] || : > "$path"`) would ALSO pass that. This races exclusive_open directly
  #     against a tight toggler for a bounded window, proving there is no separate stat-then-open gap
  #     at all, not merely a one-shot startup check.
  race_victim="$t/race_victim"; echo RACE_VICTIM_SENTINEL > "$race_victim"
  race_target="$t/race_target"
  (
    race_end=$((SECONDS + 2))
    while [ "$SECONDS" -lt "$race_end" ]; do
      ln -sf "$race_victim" "$race_target" 2>/dev/null
      rm -f "$race_target" 2>/dev/null
    done
  ) &
  race_togglerpid=$!
  race_iterations=0
  race_corrupted=0
  race_end=$((SECONDS + 2))
  { while [ "$SECONDS" -lt "$race_end" ]; do
    if exclusive_open "$race_target"; then
      printf 'owned-by-selfcheck\n' >&9
      exec 9>&-
    fi
    race_iterations=$((race_iterations + 1))
    if [ "$(cat "$race_victim")" != "RACE_VICTIM_SENTINEL" ]; then
      race_corrupted=1
      break
    fi
    rm -f "$race_target" 2>/dev/null
  done; } 2>/dev/null
  kill "$race_togglerpid" 2>/dev/null; wait "$race_togglerpid" 2>/dev/null
  [ "$race_corrupted" = 0 ] || { echo "FAIL: exclusive_open race test -- victim corrupted after $race_iterations iterations (TOCTOU reopened)"; fails=1; }
  [ "$race_iterations" -gt 20 ] || { echo "FAIL: exclusive_open race test ran suspiciously few iterations ($race_iterations) -- not a meaningful stress test"; fails=1; }

  # 8c) PRODUCTION call-site regression guard: tests 8-8b above only pin exclusive_open's own
  #     primitive. This pins the production `claude -p "$prompt_content"` call site itself -- if it
  #     ever regressed back to re-reading rendered_prompt_path by name (`claude -p "$(cat ...)"`), a
  #     background toggler continuously swapping that path for a symlink to poisoned content for the
  #     ENTIRE invocation would get the poisoned text relayed to claude's -p argument instead of the
  #     real rendered prompt.
  poison_prompt="$t/poison_prompt.txt"; printf 'POISONED_PROMPT_CONTENT_SHOULD_NEVER_REACH_CLAUDE' > "$poison_prompt"
  received_prompt="$t/received_prompt.txt"; rm -f "$received_prompt"
  log_dir="$t/run8c"; mkdir -p "$log_dir"
  prompt_target="$log_dir/sm-promptregress.prompt"
  (
    while [ ! -e "$prompt_target" ]; do :; done
    while true; do
      rm -f "$prompt_target" 2>/dev/null
      ln -sf "$poison_prompt" "$prompt_target" 2>/dev/null
    done
  ) &
  toggler8c=$!
  PATH="$fakebin:$PATH" CLAUDE_RECEIVED_PROMPT_FILE="$received_prompt" "$0" --task-id promptregress --mode solo --repo "$repo_dir" --log-dir "$log_dir" >/dev/null 2>"$t/run8c.err"
  kill "$toggler8c" 2>/dev/null; wait "$toggler8c" 2>/dev/null
  [ -f "$received_prompt" ] || { echo "FAIL: production prompt regression guard -- claude was never invoked, test is inconclusive"; fails=1; }
  grep -q 'POISONED_PROMPT_CONTENT_SHOULD_NEVER_REACH_CLAUDE' "$received_prompt" 2>/dev/null && { echo "FAIL: production claude -p call site relayed poisoned on-disk content instead of the in-memory rendered prompt"; fails=1; }

  # 8d) PRODUCTION call-site regression guard: pins the production
  #     `extracted="$(printf '%s' "$claude_output" | extract_result)"` call site -- if it ever
  #     regressed back to re-reading log_file by name, a background toggler continuously swapping
  #     that path for a symlink to a poisoned (but still full-sha-shaped) NDJSON log for the ENTIRE
  #     invocation would get the poisoned tag relayed instead of the real captured claude output.
  poison_log="$t/poison_log.ndjson"
  printf '%s\n' '{"type":"result","result":"SM_DONE_MERGED:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' > "$poison_log"
  log_dir="$t/run8d"; mkdir -p "$log_dir"
  log_target="$log_dir/sm-logregress.log"
  (
    while [ ! -e "$log_target" ]; do :; done
    while true; do
      rm -f "$log_target" 2>/dev/null
      ln -sf "$poison_log" "$log_target" 2>/dev/null
    done
  ) &
  toggler8d=$!
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=known_sha_real "$0" --task-id logregress --mode solo --repo "$repo_dir" --log-dir "$log_dir" 2>"$t/run8d.err")" || rc=$?
  kill "$toggler8d" 2>/dev/null; wait "$toggler8d" 2>/dev/null
  echo "$out" | grep -q 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' && { echo "FAIL: production extraction call site relayed the poisoned on-disk log tag instead of the real captured claude output"; fails=1; }
  echo "$out" | grep -q 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' || { echo "FAIL: production extraction call site did not relay the real tag either (rc=$rc): $(cat "$t/run8d.err")"; fails=1; }

  # 9) cross-invocation lock: two concurrent runs for the SAME task-id/log-dir must not cross-
  #    contaminate -- the second one fails fast instead of racing or reading the first one's artifacts.
  log_dir="$t/run11"; mkdir -p "$log_dir"
  ( PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=slow "$0" --task-id lockrace --mode solo --repo "$repo_dir" --log-dir "$log_dir" >"$t/run11a.out" 2>"$t/run11a.err"; echo $? > "$t/run11a.rc" ) &
  bgpid=$!
  sleep 0.3
  rc=0; PATH="$fakebin:$PATH" "$0" --task-id lockrace --mode solo --repo "$repo_dir" --log-dir "$log_dir" >"$t/run11b.out" 2>"$t/run11b.err" || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: concurrent second invocation should be refused with exit 2 (got $rc)"; fails=1; }
  grep -qi 'in flight' "$t/run11b.err" || { echo "FAIL: concurrent-run refusal message missing"; fails=1; }
  wait "$bgpid"
  [ "$(cat "$t/run11a.rc")" = "0" ] || { echo "FAIL: first (in-flight) invocation should have succeeded ($(cat "$t/run11a.rc"))"; fails=1; }

  # 10) command claude: an ambient exported `claude` shell function must never shadow the real/stub
  #     binary (this is the checker's own repro: export -f claude, then run; it must have no effect).
  # shellcheck disable=SC2329 # invoked indirectly, by name, inside the child "$0" process below
  claude() { echo HIJACKED; exit 99; }
  export -f claude
  log_dir="$t/run12"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=ok "$0" --task-id hijack1 --mode solo --repo "$repo_dir" --log-dir "$log_dir" 2>"$t/run12.err")" || rc=$?
  unset -f claude
  [ "$rc" = 0 ] || { echo "FAIL: exported claude function hijacked the real invocation (exit $rc)"; fails=1; }
  echo "$out" | grep -q 'SM_DONE_MERGED:cafef00dcafef00dcafef00dcafef00dcafef00d' || { echo "FAIL: exported claude function hijacked the real invocation's output"; fails=1; }

  # 11) non-string .result must not crash extraction (isolated) -- treated as no usable result text.
  log3="$t/r3.log"
  printf '%s\n' '{"type":"system"}' '{"type":"result","result":{"nested":"object"}}' > "$log3"
  out3="$(extract_result "$log3" 2>"$t/r3.err")"; rc3=$?
  [ "$rc3" = 0 ] || { echo "FAIL: extract_result crashed on non-string .result (exit $rc3): $(cat "$t/r3.err")"; fails=1; }
  [ -z "$out3" ] || { echo "FAIL: extract_result should yield no text for a non-string .result, got: $out3"; fails=1; }

  # 12) same, end-to-end: a non-string .result in the real NDJSON stream must relay as "no usable
  #     tag" (exit 3), never crash the script with an uncaught Python traceback.
  log_dir="$t/run14"; mkdir -p "$log_dir"
  rc=0; PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=non_string_result "$0" --task-id nsr1 --mode solo --repo "$repo_dir" --log-dir "$log_dir" >/dev/null 2>"$t/run14.err" || rc=$?
  [ "$rc" = 3 ] || { echo "FAIL: non-string .result end-to-end should exit 3 (no usable tag), got $rc: $(cat "$t/run14.err")"; fails=1; }
  grep -q 'Traceback' "$t/run14.err" && { echo "FAIL: non-string .result leaked a Python traceback (extraction crashed, exit 3 was coincidental, not graceful)"; fails=1; }

  # 13) full-sha discipline: a SM_DONE_MERGED/SM_READY_UNMERGED tag whose value is NOT a full 40-hex
  #     git SHA (the checker's own repro used an 8-char "cafef00d") must be treated the same as a
  #     malformed/no-usable-tag result -- exit 3, never relayed as a successful completion.
  log_dir="$t/run_shortsha1"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=short_sha_done "$0" --task-id shortsha1 --mode solo --repo "$repo_dir" --log-dir "$log_dir" 2>"$t/run_shortsha1.err")" || rc=$?
  [ "$rc" = 3 ] || { echo "FAIL: non-full-sha SM_DONE_MERGED should be treated as malformed, exit 3 (got $rc)"; fails=1; }
  echo "$out" | grep -q '^malformed$' || { echo "FAIL: non-full-sha SM_DONE_MERGED not reported as malformed, got: $out"; fails=1; }

  log_dir="$t/run_shortsha2"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=short_sha_ready "$0" --task-id shortsha2 --mode solo --repo "$repo_dir" --log-dir "$log_dir" 2>"$t/run_shortsha2.err")" || rc=$?
  [ "$rc" = 3 ] || { echo "FAIL: non-full-sha SM_READY_UNMERGED should be treated as malformed, exit 3 (got $rc)"; fails=1; }
  echo "$out" | grep -q '^malformed$' || { echo "FAIL: non-full-sha SM_READY_UNMERGED not reported as malformed, got: $out"; fails=1; }

  # --- drift tripwire: SKILL.md's own numbered/lettered step counts must still match the templates ---
  skill="$SCRIPT_DIR/../skills/secondmate/SKILL.md"
  solo_skill_n="$(sed -n '/^### Solo dispatch/,/^### Batch dispatch/p' "$skill" | grep -cE '^[0-9]+\. ')"
  batch_skill_n="$(sed -n '/^### Batch dispatch/,/^\*\*The dispatcher.s own role/p' "$skill" | grep -cE '^[a-d]\. \*\*')"
  solo_tmpl_n="$(grep -cE '^[0-9]+\. ' "$SCRIPT_DIR/spawn-sub-sup-prompt-solo.txt")"
  batch_tmpl_n="$(grep -cE '^[a-d]\. \*\*' "$SCRIPT_DIR/spawn-sub-sup-prompt-batch.txt")"
  [ "$solo_skill_n" = "$solo_tmpl_n" ] || { echo "FAIL: solo step count drift -- SKILL.md has $solo_skill_n, template has $solo_tmpl_n"; fails=1; }
  [ "$batch_skill_n" = "$batch_tmpl_n" ] || { echo "FAIL: batch step count drift -- SKILL.md has $batch_skill_n, template has $batch_tmpl_n"; fails=1; }

  rm -rf "$t"
  [ "$fails" = 0 ] && echo ok
  exit "$fails"
fi

task_id="" mode="" batch_id="" repo="$(pwd)" log_dir="/tmp" prompt_file_override=""
while [ $# -gt 0 ]; do
  case "$1" in
    --task-id) [ $# -ge 2 ] || { echo "--task-id requires a value" >&2; exit 2; }; task_id="$2"; shift 2;;
    --mode) [ $# -ge 2 ] || { echo "--mode requires a value" >&2; exit 2; }; mode="$2"; shift 2;;
    --batch-id) [ $# -ge 2 ] || { echo "--batch-id requires a value" >&2; exit 2; }; batch_id="$2"; shift 2;;
    --repo) [ $# -ge 2 ] || { echo "--repo requires a value" >&2; exit 2; }; repo="$2"; shift 2;;
    --log-dir) [ $# -ge 2 ] || { echo "--log-dir requires a value" >&2; exit 2; }; log_dir="$2"; shift 2;;
    --prompt-file) [ $# -ge 2 ] || { echo "--prompt-file requires a value" >&2; exit 2; }; prompt_file_override="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$task_id" ] || { echo "need --task-id ID" >&2; exit 2; }
[ -n "$mode" ] || { echo "need --mode solo|batch" >&2; exit 2; }
case "$mode" in
  solo|batch) ;;
  *) echo "invalid --mode '$mode' (want solo|batch)" >&2; exit 2;;
esac
if [ "$mode" = "batch" ] && [ -z "$batch_id" ]; then
  echo "--mode batch requires --batch-id" >&2; exit 2
fi
if [ "$mode" = "solo" ] && [ -n "$batch_id" ]; then
  echo "--mode solo rejects --batch-id (contract mismatch: solo dispatch has no batch to correlate against)" >&2
  exit 2
fi

validate_id task-id "$task_id"
[ -n "$batch_id" ] && validate_id batch-id "$batch_id"

repo="$(cd "$repo" 2>/dev/null && pwd)" || { echo "no such --repo directory" >&2; exit 2; }
mkdir -p "$log_dir"
owner="sm-${task_id}"

# Cross-invocation guard: two concurrent runs for the SAME task-id/log-dir would otherwise share the
# exact same prompt/log/result paths, letting one read and relay the OTHER's claude output. Fail fast
# instead of racing. Released on every exit path via the trap below (success, crash, violation, etc).
lock_dir="${log_dir}/.sm-${task_id}.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "SPAWN-SUB-SUP: another spawn-sub-sup.sh invocation for task-id '$task_id' in --log-dir '$log_dir' appears to be in flight (lock dir exists: $lock_dir) -- refusing to risk cross-invocation artifact collision" >&2
  exit 2
fi
trap 'rmdir "$lock_dir" 2>/dev/null' EXIT

if [ -n "$prompt_file_override" ]; then
  template_file="$prompt_file_override"
else
  template_file="$SCRIPT_DIR/spawn-sub-sup-prompt-${mode}.txt"
fi
[ -f "$template_file" ] || { echo "template file not found: $template_file" >&2; exit 2; }
[ -r "$template_file" ] || { echo "template file not readable: $template_file -- refusing to launch claude with an empty/partial prompt" >&2; exit 2; }

# Render the prompt into a bash variable (never re-read from disk) -- this is the exact string later
# fed to `claude -p`, so there is no window after this point where an attacker could swap the on-disk
# .prompt artifact for a symlink to attacker-controlled content and have it silently re-trusted.
prompt_content="$(render_prompt "$mode" "$task_id" "$owner" "$repo" "$batch_id" "$template_file")"

rendered_prompt_path="${log_dir}/sm-${task_id}.prompt"
if ! exclusive_open "$rendered_prompt_path"; then
  echo "SPAWN-SUB-SUP: refusing to write -- a file or symlink already exists at: $rendered_prompt_path" >&2
  exit 2
fi
printf '%s' "$prompt_content" >&9
exec 9>&-

log_file="${log_dir}/sm-${task_id}.log"
result_file="${log_dir}/sm-${task_id}.result"
# Open log_file's fd now (before claude ever runs) so an unwritable/pre-existing-symlink log path is
# refused without wasting a real claude invocation -- but keep the fd open and write to it only AFTER
# claude's full output is captured below, so the actual persist-to-disk write still goes through this
# SAME already-open fd, never a second, path-based reopen.
if ! exclusive_open "$log_file"; then
  echo "SPAWN-SUB-SUP: refusing to write -- a file or symlink already exists at: $log_file" >&2
  exit 2
fi

# Capture claude's own exit status in the SAME if/then/else statement set -e would otherwise inspect
# (and here would also skip past under `set -e` with pipefail if written on a trailing line) --
# a nonzero/killed exit must be caught here, not lost by falling through to the lines below.
# `command claude` (not a bare `claude` call) bypasses shell function lookup -- an ambient/exported
# `claude` function can otherwise shadow the real binary (or, in --selfcheck, the synthetic stub).
# Captured into a variable (not redirected to a file by path) so the result-tag extraction below can
# consume it directly, with no re-open of the log artifact's path after the fact.
if claude_output="$( ( cd "$repo" && command claude -p "$prompt_content" --dangerously-skip-permissions --output-format stream-json --verbose ) 2>&1 )"; then
  claude_rc=0
else
  claude_rc=$?
fi

printf '%s' "$claude_output" >&9
exec 9>&-

if [ "$claude_rc" -ne 0 ]; then
  echo "SPAWN-SUB-SUP: CLAUDE SUBPROCESS CRASHED OR WAS KILLED (exit $claude_rc) -- see $log_file. dispatch-report.py was NOT invoked." >&2
  exit 5
fi

# Extract directly from the in-memory claude_output (stdin mode), never by re-opening log_file by
# path -- the previous round's exclusive_open only guaranteed a race-free CREATE; a later re-open by
# name for the actual read would have thrown that guarantee away just as surely as skipping it.
extracted="$(printf '%s' "$claude_output" | extract_result)"

if ! exclusive_open "$result_file"; then
  echo "SPAWN-SUB-SUP: refusing to write -- a file or symlink already exists at: $result_file" >&2
  exit 2
fi
printf '%s' "$extracted" >&9
exec 9>&-

# Feed dispatch-report.py the in-memory extracted text directly (it already documents stdin support
# for this exact case), never a re-open of result_file by path -- the same re-read-by-path shape
# findings 1 and 2 (last round) closed for the prompt and the log applies identically here: a
# concurrent attacker could otherwise swap result_file for a symlink to attacker-controlled NDJSON
# between the exclusive_open write above and this read, turning a real SM_REFUSED into a relayed
# SM_DONE_MERGED.
if dispatch_out="$(printf '%s' "$extracted" | "$SCRIPT_DIR/dispatch-report.py")"; then
  dispatch_rc=0
else
  dispatch_rc=$?
fi

# Full-sha discipline: a SM_DONE_MERGED/SM_READY_UNMERGED tag whose value is NOT a full, standard
# git SHA (40 hex chars) is not a genuine completion signal -- treat it exactly like
# dispatch-report.py's own malformed/no-tag case ("malformed", exit 3), never relay it as success.
if [[ "$dispatch_out" == SM_DONE_MERGED:* || "$dispatch_out" == SM_READY_UNMERGED:* ]] \
   && [[ ! "$dispatch_out" =~ ^(SM_DONE_MERGED|SM_READY_UNMERGED):[0-9a-fA-F]{40}$ ]]; then
  dispatch_out="malformed"
  dispatch_rc=3
fi

echo "$dispatch_out"

claim_line="$(printf '%s' "$extracted" | grep -m1 '^SM_CLAIM_TOKEN:' || true)"
[ -n "$claim_line" ] && echo "$claim_line"

final_rc="$dispatch_rc"
if [ "$mode" = "batch" ] && [[ "$dispatch_out" == SM_DONE_MERGED:* ]]; then
  violation_line="$(printf '%s' "$extracted" | grep -m1 '^SM_DONE_MERGED:' || true)"
  echo "SPAWN-SUB-SUP: BATCH SELF-MERGE CONTRACT VIOLATION -- a --mode batch sub-supervisor must stop at verify_gate_pass and emit SM_READY_UNMERGED, never merge/hold itself. Raw tag: ${violation_line:-$dispatch_out}" >&2
  final_rc=2
fi

exit "$final_rc"
