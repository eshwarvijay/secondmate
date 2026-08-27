#!/usr/bin/env bash
# launch-checker.sh -- always edit-locked cross-model checker. --exclude-tools edit,write is hardcoded so a
# checker can never mutate the maker's work. Injects the base checker discipline + the verdict-envelope
# contract, then your per-task addendum. Harness/provider/model/prompt are env-configurable for portability.
#   launch-checker.sh --addendum FILE | --addendum-text "..."  [--lens redteam,qa,...] [--model M|terra|sol|luna] [--thinking L] -- [extra args]
#   --lens NAME[,NAME] (repeatable): layer specialized role disciplines from bin/lenses/<NAME>.md on top of the base checker.
# Env: SM_CHECKER_HARNESS(pi) SM_CHECKER_PROVIDER(amazon-bedrock) SM_CHECKER_MODEL(global.openai.gpt-5.6-terra)
#      SM_CHECKER_THINKING(high) SM_CHECKER_PROMPT(<plugin>/bin/checker-prompt.md)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--selfcheck" ]; then
  fails=0
  rc=0; "$0" -- -p q >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: no-addendum exit $rc (want 2)"; fails=1; }
  rc=0; "$0" --addendum-text x --lens __nope__ -- -p q >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: unknown-lens exit $rc (want 2)"; fails=1; }
  rc=0; SM_CHECKER_PROMPT=/nonexistent-xyz "$0" --addendum-text x -- -p q >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || { echo "FAIL: missing-prompt exit $rc (want 1)"; fails=1; }
  [ "$fails" = 0 ] && echo ok; exit "$fails"
fi

harness="${SM_CHECKER_HARNESS:-pi}"
provider="${SM_CHECKER_PROVIDER:-amazon-bedrock}"
model="${SM_CHECKER_MODEL:-global.openai.gpt-5.6-terra}"
thinking="${SM_CHECKER_THINKING:-high}"
base_prompt="${SM_CHECKER_PROMPT:-$SCRIPT_DIR/checker-prompt.md}"
addendum_file="" addendum_text=""; lenses=()
while [ $# -gt 0 ]; do
  case "$1" in
    --addendum) addendum_file="$2"; shift 2;;
    --addendum-text) addendum_text="$2"; shift 2;;
    --lens) lenses+=("$2"); shift 2;;
    --model) case "$2" in terra|sol|luna) model="global.openai.gpt-5.6-$2";; *) model="$2";; esac; shift 2;;
    --thinking) thinking="$2"; shift 2;;
    --) shift; break;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -f "$base_prompt" ] || { echo "missing base checker discipline: $base_prompt (set SM_CHECKER_PROMPT)" >&2; exit 1; }
addendum=""
if [ -n "$addendum_file" ]; then
  [ -f "$addendum_file" ] || { echo "addendum file not found: $addendum_file" >&2; exit 1; }
  addendum="$(cat "$addendum_file")"
elif [ -n "$addendum_text" ]; then
  addendum="$addendum_text"
else
  echo "need --addendum FILE or --addendum-text (what to hammer for THIS diff)" >&2; exit 2
fi

# The verdict envelope + report contract; injected if present so the checker always emits a
# machine-branchable {verdict,...} block. Delete the file to disable.
envelope="$SCRIPT_DIR/checker-envelope.md"
envelope_arg=()
[ -f "$envelope" ] && envelope_arg=(--append-system-prompt "$(cat "$envelope")")

# Optional role lenses (--lens redteam,qa,...): specialized checker disciplines from bin/lenses/, layered
# on top of the base correctness discipline. Fail loud on an unknown lens.
lens_args=()
for _l in "${lenses[@]:-}"; do
  [ -n "$_l" ] || continue
  IFS=',' read -ra _names <<< "$_l"
  for _n in "${_names[@]}"; do
    _lf="$SCRIPT_DIR/lenses/$_n.md"
    [ -f "$_lf" ] || { echo "unknown lens: $_n (looked for $_lf). Available: $( (cd "$SCRIPT_DIR/lenses" 2>/dev/null && find . -name '*.md' ! -name 'ROUTER.md' | sed 's|^\./||;s|\.md$||') | tr '\n' ' ')" >&2; exit 2; }
    lens_args+=(--append-system-prompt "$(cat "$_lf")")
  done
done

# No harness installed? Signal the supervisor to use the in-session Claude checker fallback (see the skill),
# instead of crashing with a raw "command not found". Exit 3 is the fallback signal.
if ! command -v "$harness" >/dev/null 2>&1; then
  echo "SM_NO_CHECKER_HARNESS: '$harness' not found. Fall back to an in-session checker: spawn a Claude sub-agent on a DIFFERENT model than the maker, review-only, with $base_prompt plus the verdict envelope plus the diff, then run its output through verdict.py. For a stronger cross-vendor check install a harness: npm install -g @earendil-works/pi-coding-agent" >&2
  exit 3
fi

# --exclude-tools edit,write is NOT optional: it makes the checker physically read-only.
exec "$harness" --provider "$provider" --model "$model" \
  --thinking "$thinking" --exclude-tools edit,write \
  --append-system-prompt "$(cat "$base_prompt")" \
  "${lens_args[@]}" \
  "${envelope_arg[@]}" \
  --append-system-prompt "$addendum" \
  "$@"
