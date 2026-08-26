#!/usr/bin/env bash
# launch-checker.sh -- always edit-locked cross-model checker. --exclude-tools edit,write is hardcoded so a
# checker can never mutate the maker's work. Injects the base checker discipline + the verdict-envelope
# contract, then your per-task addendum. Harness/provider/model/prompt are env-configurable for portability.
#   launch-checker.sh --addendum FILE | --addendum-text "..."  [--model M|terra|sol|luna] [--thinking L] -- [extra args]
# Env: SM_CHECKER_HARNESS(pi) SM_CHECKER_PROVIDER(amazon-bedrock) SM_CHECKER_MODEL(global.openai.gpt-5.6-terra)
#      SM_CHECKER_THINKING(high) SM_CHECKER_PROMPT(<plugin>/bin/checker-prompt.md)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

harness="${SM_CHECKER_HARNESS:-pi}"
provider="${SM_CHECKER_PROVIDER:-amazon-bedrock}"
model="${SM_CHECKER_MODEL:-global.openai.gpt-5.6-terra}"
thinking="${SM_CHECKER_THINKING:-high}"
base_prompt="${SM_CHECKER_PROMPT:-$SCRIPT_DIR/checker-prompt.md}"
addendum_file="" addendum_text=""
while [ $# -gt 0 ]; do
  case "$1" in
    --addendum) addendum_file="$2"; shift 2;;
    --addendum-text) addendum_text="$2"; shift 2;;
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

# --exclude-tools edit,write is NOT optional: it makes the checker physically read-only.
exec "$harness" --provider "$provider" --model "$model" \
  --thinking "$thinking" --exclude-tools edit,write \
  --append-system-prompt "$(cat "$base_prompt")" \
  "${envelope_arg[@]}" \
  --append-system-prompt "$addendum" \
  "$@"
