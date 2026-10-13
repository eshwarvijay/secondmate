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
# are skipped silently -- NDJSON streams can interleave non-result events freely.
extract_result() {
  python3 -c '
import json, sys
last = None
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict) and obj.get("type") == "result" and "result" in obj:
            last = obj["result"]
if last is not None:
    sys.stdout.write(last)
' "$1"
}

if [ "${1:-}" = "--selfcheck" ]; then
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
    printf '%s\n' '{"type":"result","result":"work done\nSM_DONE_MERGED:deadbeef"}'
    ;;
  claim_token)
    echo '{"type":"system"}'
    printf '%s\n' '{"type":"result","result":"SM_CLAIM_TOKEN:tok-xyz\nSM_READY_UNMERGED:cafef00d"}'
    ;;
  *)
    echo '{"type":"system"}'
    echo '{"type":"result","result":"SM_DONE_MERGED:cafef00d"}'
    ;;
esac
FAKE
  chmod +x "$fakebin/claude"
  repo_dir="$t/repo"; mkdir -p "$repo_dir"

  # 1) ordinary solo success: dispatch-report.py's own exit 0, result relayed, no crash/violation noise.
  log_dir="$t/run1"; mkdir -p "$log_dir"
  rc=0; out="$(PATH="$fakebin:$PATH" FAKE_CLAUDE_BEHAVIOR=ok "$0" --task-id ok1 --mode solo --repo "$repo_dir" --log-dir "$log_dir" 2>"$t/run1.err")" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: ordinary solo success exit ($rc)"; fails=1; }
  echo "$out" | grep -q 'SM_DONE_MERGED:cafef00d' || { echo "FAIL: ordinary solo success did not relay dispatch-report.py output"; fails=1; }

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

if [ -n "$prompt_file_override" ]; then
  template_file="$prompt_file_override"
else
  template_file="$SCRIPT_DIR/spawn-sub-sup-prompt-${mode}.txt"
fi
[ -f "$template_file" ] || { echo "template file not found: $template_file" >&2; exit 2; }

rendered_prompt_path="${log_dir}/sm-${task_id}.prompt"
render_prompt "$mode" "$task_id" "$owner" "$repo" "$batch_id" "$template_file" > "$rendered_prompt_path"

log_file="${log_dir}/sm-${task_id}.log"
result_file="${log_dir}/sm-${task_id}.result"

# Capture claude's own exit status in the SAME if/then/else statement set -e would otherwise inspect
# (and here would also skip past under `set -e` with pipefail if written on a trailing line) --
# a nonzero/killed exit must be caught here, not lost by falling through to the lines below.
if ( cd "$repo" && claude -p "$(cat "$rendered_prompt_path")" --dangerously-skip-permissions --output-format stream-json --verbose ) > "$log_file" 2>&1; then
  claude_rc=0
else
  claude_rc=$?
fi

if [ "$claude_rc" -ne 0 ]; then
  echo "SPAWN-SUB-SUP: CLAUDE SUBPROCESS CRASHED OR WAS KILLED (exit $claude_rc) -- see $log_file. dispatch-report.py was NOT invoked." >&2
  exit 5
fi

extract_result "$log_file" > "$result_file"

if dispatch_out="$("$SCRIPT_DIR/dispatch-report.py" "$result_file")"; then
  dispatch_rc=0
else
  dispatch_rc=$?
fi

echo "$dispatch_out"

claim_line="$(grep -m1 '^SM_CLAIM_TOKEN:' "$result_file" || true)"
[ -n "$claim_line" ] && echo "$claim_line"

final_rc="$dispatch_rc"
if [ "$mode" = "batch" ] && [[ "$dispatch_out" == SM_DONE_MERGED:* ]]; then
  violation_line="$(grep -m1 '^SM_DONE_MERGED:' "$result_file" || true)"
  echo "SPAWN-SUB-SUP: BATCH SELF-MERGE CONTRACT VIOLATION -- a --mode batch sub-supervisor must stop at verify_gate_pass and emit SM_READY_UNMERGED, never merge/hold itself. Raw tag: ${violation_line:-$dispatch_out}" >&2
  final_rc=2
fi

exit "$final_rc"
