#!/usr/bin/env bash
# plan-committee.sh -- multi-model planning committee: N pi headless planners in parallel.
# Each uses a different Bedrock model and covers one planning dimension of the task.
# Outputs land in $out_dir/<label>.md; the supervisor reads them and synthesizes the plan.
# The Claude /adhd agent is NOT invoked here — the supervisor runs it separately (Claude Code skill).
#
# Usage: plan-committee.sh --task TEXT [--out-dir DIR] [--timeout S]
# Env:   SM_COMMITTEE_PROVIDER   (default: amazon-bedrock)
#        SM_COMMITTEE_TIMEOUT    (default: 300 seconds per planner)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROVIDER="${SM_COMMITTEE_PROVIDER:-amazon-bedrock}"

# label|dimension|model-id|thinking-level
# ponytail: thinking=high only for native reasoning models (R1, Kimi-K2), off for others
PLANNERS=(
  "deepseek-r1|Failure modes, edge cases, and what can go wrong|deepseek.r1-v1:0|high"
  "qwen3-235b|Technical architecture and system design trade-offs|qwen.qwen3-235b-a22b-2507-v1:0|off"
  "qwen3-coder|Implementation feasibility and concrete code path|qwen.qwen3-coder-480b-a35b-v1:0|off"
  "kimi-k2|Holistic long-context risk and integration review|moonshot.kimi-k2-thinking|high"
  "mistral-large3|Security surface, adversarial gaps, and attack vectors|mistral.mistral-large-3-675b-instruct|off"
  "glm5|Structured requirements, product angle, and user-facing concerns|zai.glm-5|off"
)

SCHEMA='Respond using ONLY this exact format — no preamble, no extra sections:

## Approach
(Your recommended approach for this task from your assigned dimension)

## Key decisions
(The 3-5 most important decisions this task requires)

## Risks
(What can go wrong — be specific, not generic)

## What I would skip
(What is unnecessary or over-engineered for this task)'

# ---- arg parsing ----
task="" out_dir="${SM_LOOP_STATE:-.secondmate}/planning" timeout="${SM_COMMITTEE_TIMEOUT:-300}"
while [ $# -gt 0 ]; do case "$1" in
  --task)    [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; task="$2"; shift 2;;
  --out-dir) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; out_dir="$2"; shift 2;;
  --timeout) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; timeout="$2"; shift 2;;
  --selfcheck)
    rc=0; "$0" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || { echo "FAIL: no-task exit $rc (want 2)"; exit 1; }
    echo ok; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$task" ] || { echo "need --task TEXT" >&2; exit 2; }

mkdir -p "$out_dir"

# ---- launch all planners in parallel ----
pids=(); labels=(); outs=()
for entry in "${PLANNERS[@]}"; do
  IFS='|' read -r label dimension model_id thinking <<< "$entry"
  out="$out_dir/$label.md"
  prompt="You are a planning agent. Your assigned dimension: $dimension.

TASK:
$task

$SCHEMA"
  "$SCRIPT_DIR/run-round.sh" \
    --label "plan-$label" --log "$out" \
    --timeout "$timeout" --audit "$out_dir/audit.jsonl" \
    -- pi --provider "$PROVIDER" --model "$model_id" --thinking "$thinking" --no-tools -p "$prompt" &
  pids+=($!); labels+=("$label"); outs+=("$out")
done

# ---- wait for all ----
failed=0
for i in "${!pids[@]}"; do
  wait "${pids[$i]}" || { echo "planner ${labels[$i]} failed or timed out" >&2; failed=1; }
done

# ---- summary ----
echo "=== Planning committee ==="
for i in "${!labels[@]}"; do
  f="${outs[$i]}"
  if [ -f "$f" ] && [ -s "$f" ]; then
    echo "  + ${labels[$i]} ($(wc -l < "$f") lines) -> $f"
  else
    echo "  - ${labels[$i]}: missing or empty"
    failed=1
  fi
done
echo ""
echo "Next: read files above + .secondmate/planning/adhd.md (from your /adhd subagent),"
echo "synthesize into a consolidated plan, then route to maker."

exit "$failed"
