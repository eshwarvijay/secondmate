#!/usr/bin/env bash
# reason.sh -- reasoning-heavy one-shot on a read-only, TOOL-FREE reasoning model, so the supervisor doesn't
# burn its own context on root-cause / triage / plan-review / pre-mortem analysis.
#   reason.sh [--model r1|gpt|sonnet|<id>] [--thinking high|xhigh|off] [--context FILE ...] ["question"]
#   echo "question" | reason.sh --context diff.txt ;  reason.sh --dry-run ... ;  reason.sh --selfcheck
# Env: SM_REASON_HARNESS(pi) SM_REASON_PROVIDER(amazon-bedrock) SM_REASON_MODEL(default alias when no --model)
set -euo pipefail

resolve_model() {
  case "$1" in
    r1)     echo "us.deepseek.r1-v1:0";;
    gpt)    echo "global.openai.gpt-5.6-terra";;
    sonnet) echo "us.anthropic.claude-sonnet-5";;
    *)      echo "$1";;
  esac
}

reason() {
  local model_alias="${SM_REASON_MODEL:-r1}" thinking="high" dry=0 question=""
  local harness="${SM_REASON_HARNESS:-pi}" provider="${SM_REASON_PROVIDER:-amazon-bedrock}"
  local -a contexts=()
  while [ $# -gt 0 ]; do case "$1" in
    --model) model_alias="${2:?value required for $1}"; shift 2;;
    --thinking) thinking="${2:?value required for $1}"; shift 2;;
    --context) contexts+=("$2"); shift 2;;
    --dry-run) dry=1; shift;;
    --) shift; question="$*"; break;;
    -*) echo "unknown arg: $1" >&2; return 2;;
    *) question="$1"; shift;;
  esac; done

  if [ -z "$question" ] && [ ! -t 0 ]; then question="$(cat)"; fi
  [ -n "$question" ] || { echo "need a question (as an argument or on stdin)" >&2; return 2; }

  local prompt="" f
  for f in "${contexts[@]:-}"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || { echo "context file not found: $f" >&2; return 2; }
    prompt+="=== context: $f ==="$'\n'"$(cat "$f")"$'\n\n'
  done
  prompt+="$question"

  local model; model="$(resolve_model "$model_alias")"
  local -a args=(-p --no-tools --provider "$provider" --model "$model")
  case "$thinking" in ""|off|none) ;; *) args+=(--thinking "$thinking");; esac
  args+=("$prompt")

  if [ "$dry" = 1 ]; then printf '%s' "$harness"; printf ' %q' "${args[@]}"; printf '\n'; return 0; fi
  exec "$harness" "${args[@]}"
}

if [ "${1:-}" = "--selfcheck" ]; then
  unset SM_REASON_MODEL SM_REASON_HARNESS SM_REASON_PROVIDER
  tmp="$(mktemp)"; printf 'DIFF-CONTENT-XYZ' >"$tmp"; r=0
  out="$(reason --dry-run --model gpt --thinking xhigh --context "$tmp" "why does login fail?")"
  echo "$out" | grep -q -- '--no-tools'        || { echo "FAIL: missing --no-tools"; r=1; }
  echo "$out" | grep -q 'gpt-5.6-terra'         || { echo "FAIL: model alias not resolved"; r=1; }
  echo "$out" | grep -q 'login'                 || { echo "FAIL: question not in prompt"; r=1; }
  echo "$out" | grep -q 'DIFF-CONTENT-XYZ'      || { echo "FAIL: context not inlined"; r=1; }
  echo "$out" | grep -q -- '--thinking xhigh'   || { echo "FAIL: thinking not passed"; r=1; }
  out2="$(reason --dry-run --thinking off "q")"
  if echo "$out2" | grep -q -- '--thinking'; then echo "FAIL: off should omit --thinking"; r=1; fi
  echo "$out2" | grep -q 'deepseek.r1'          || { echo "FAIL: default model should be r1"; r=1; }
  rm -f "$tmp"; [ "$r" = 0 ] && echo ok; exit "$r"
fi

reason "$@"
