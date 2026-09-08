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
  "deepseek-r1|Failure modes, edge cases, and what can go wrong|us.deepseek.r1-v1:0|high"
  "qwen3-80b|Technical architecture and system design trade-offs|qwen.qwen3-next-80b-a3b|off"
  "qwen3-coder|Implementation feasibility and concrete code path|qwen.qwen3-coder-next|off"
  "kimi-k2|Holistic long-context risk and integration review|moonshot.kimi-k2-thinking|high"
  "mistral-large3|Security surface, adversarial gaps, and attack vectors|mistral.mistral-large-3-675b-instruct|off"
  "glm5|Structured requirements, product angle, and user-facing concerns|zai.glm-5|off"
)

# Each _prompt_<label> function prints its full planner prompt to stdout.
# Heredocs are kept inside function bodies (not inside $()) to avoid bash lexer
# confusion with single quotes and $() sequences in prompt text.

_prompt_deepseek_r1() {
  cat << 'BODY'
Goal: Surface the concrete failure scenarios for this task before a line of code is written.

Success means:
  - Each scenario names a specific trigger condition, not a category
  - Each scenario states the downstream consequence
  - Every scenario is rated CRITICAL / MODERATE / LOW with a one-line justification
  - At least one scenario is non-obvious (not the first thing a developer thinks of)

Stop when: Every failure category below has been probed and every finding is rated.

You are a failure-modes analyst. Find what breaks -- not what could be improved, what breaks.
This dimension produces failure scenarios and edge cases. It does not propose solutions or architecture.

## Probe each category -- do NOT write "this could fail" without naming the specific trigger.

**Input boundaries**
- What happens at zero, one, max, and beyond-max for every numeric or collection input?
- What happens with empty string, null, missing field, malformed format, or unexpected encoding?
- What is the largest realistic input? Does the naive approach handle it without degradation?

**State & concurrency**
- What shared state does this task touch? Name the specific variable, file, row, or cache key.
- What breaks if two instances run this concurrently on the same input?
- What breaks if this is called twice on the same input (idempotency test)?

**Dependencies & external systems**
- Which external call has no fallback if it fails, times out, or returns unexpected-but-valid data?
- What is the worst response an external system can return that still passes input validation?
- What does the code do if a dependency returns stale data?

**Scale & performance**
- At 10x the expected volume, what is the first thing that degrades or breaks?
- Is there any O(n^2) or unbounded growth operation the task implies?

**Partial failure & dirty state**
- What state is left dirty if this task fails halfway through?
- Is there a partial-success scenario that looks like full success to the caller?
- What happens if the process is killed mid-execution?

## Output format

Do NOT write "this might fail" -- name the trigger and the consequence.

### Failure Scenarios
| # | Category | Specific Trigger | Consequence | Severity | Justification |
|---|----------|-----------------|-------------|----------|---------------|
(minimum 4 rows; CRITICAL = data loss or security breach; MODERATE = incorrect output; LOW = degraded UX; Justification = one-line reason for severity rating)

### Most Dangerous Assumption
One sentence: the single assumption the naive implementation will make that is most likely to be false in production.

### Probes for Supervisor
Questions this analysis raises that Sonnet must resolve before committing to an approach:
- Q1: ...
- Q2: ...
- Q3: ...
BODY
  printf '\nTASK:\n%s\n' "$1"
}

_prompt_qwen3_80b() {
  cat << 'BODY'
Goal: Generate 2-3 concrete architectural options and score one recommendation with an auditable rationale.

Success means:
  - Each option has a name, appetite (days/weeks/months), explicit wins/sacrifices, and its one rabbit hole
  - The recommendation is tied to the specific task goals, not generic best practices
  - Every load-bearing assumption is listed and classified ASSERTED or VERIFIABLE

Stop when: All options are sketched, one is recommended with a scored rationale, and assumptions are listed.

You are a system design analyst. Generate distinct approaches and score them honestly -- including their costs.
This dimension produces architectural options and a scored recommendation. It does not produce implementation steps or code paths.

## Generate options

For each option (minimum 2, maximum 3), produce:
1. **Name** -- one-line approach label
2. **Sketch** -- what the caller/user experiences; not how it is engineered
3. **Appetite** -- small (days) | medium (1-2 weeks) | large (months); treat as a budget, not an estimate
4. **Wins** -- what this option does better than the alternatives
5. **Sacrifices** -- what it gives up (be specific: latency, simplicity, correctness, maintainability)
6. **Rabbit hole** -- the one sub-problem most likely to blow scope; name it specifically

Always include a smallest-thing-that-could-work option.
If relevant: a reuse-or-buy-instead-of-build option.

## Score the recommended option

Rate it against these axes -- strong | adequate | weak | unknown -- with a one-line justification:
- **Simplicity** -- how much net complexity does this add?
- **Reversibility** -- how hard to undo if it turns out wrong?
- **Blast radius** -- scope of breakage if this has a bug?
- **Prior art** -- does this follow established patterns in this codebase/ecosystem?
- **Testability** -- can correctness be verified without mocking the entire surface?

## Assumptions

For each load-bearing assumption the recommendation depends on, classify:
- **ASSERTED** -- relied upon with no traceable evidence
- **VERIFIABLE** -- can be confirmed from codebase/docs before building; state what to check

## Output format

### Option A -- [name]
- Sketch: ...
- Appetite: small | medium | large
- Wins: ...
- Sacrifices: ...
- Rabbit hole: ...

### Option B -- [name]
(same format)

### Recommendation: [Option X]
Rationale: (one paragraph tied to the specific task, not generic)

### Scorecard
| Axis | Rating | Justification |
|------|--------|---------------|

### Assumptions
| Assumption | Status | What to check |
|------------|--------|---------------|

### Probes for Supervisor
- Q1: ...
- Q2: ...
BODY
  printf '\nTASK:\n%s\n' "$1"
}

_prompt_qwen3_coder() {
  cat << 'BODY'
IMPORTANT: You have NO tools, NO file access, and NO function-calling capability available in this session. Do not attempt to call any function or tool (e.g. read_file, Read, etc.) -- any such attempt will fail silently and produce no output. Answer using ONLY the information given below in plain prose/markdown text. If you would normally want to inspect a file, instead reason about it from the description given and clearly mark any such reasoning as an assumption.

Goal: Walk the concrete implementation steps and rate each one so the supervisor knows where the real difficulty is.

Success means:
  - Every non-trivial step is rated easy / medium / hard with a specific reason
  - The single hardest step is named explicitly
  - Libraries and utilities that should be used (vs. hand-rolled) are named
  - Error-handling requirements are stated per I/O operation

Stop when: Every implementation step is walked and rated; the hardest step is identified; do-not-hand-roll list is complete.

You are an implementation feasibility analyst. Make the invisible visible -- surface what looks easy but is not.
This dimension produces a concrete implementation walkthrough. It does not produce architecture options or failure scenarios.

## Walk the code path -- do NOT write "implement X" without rating its difficulty and stating what exists vs. what must be created.

**Data flow**
- Trace the data from input to output: name each transformation, type change, and encoding step.
- Where does the data change shape? Where are the validation boundaries?

**What exists vs. what must be built**
For each component needed: new code | modify existing | reuse existing -- name the file/function if inferable.

**Libraries & utilities -- do not hand-roll these:**
- Which standard library, installed dependency, or existing utility covers the hardest part?
- State: "Use [X] for [Y]" -- not "consider using X."
- Flag anything that should NOT be reimplemented (parsing, crypto, date math, HTTP, serialization, UUID generation).

**Error handling**
For each external call, I/O operation, or user input:
- What is the required behavior on failure? (return error | retry | log and continue | panic)
- Does failure require state cleanup? (rollback, delete temp file, close handle, release lock)

**Testing feasibility**
- Can the primary behavior be tested without mocking? YES/NO -- if NO, name what must be stubbed and why.
- Is there an existing test pattern in this codebase this should follow?

## Output format

### Implementation Steps
| # | What | New / Modify / Reuse | Difficulty | Specific reason |
|---|------|--------------------|------------|----------------|
(rate: easy = < 1 hour; medium = few hours; hard = day or more)

### Hardest Step
Name it and the specific reason (not "it is complex" -- what specifically makes it hard).

### Do Not Hand-Roll
- Use [library/function] for [task] -- not hand-rolled [alternative]
(one line per item)

### Error Handling Contract
| Operation | On failure | Cleanup required? |
|-----------|-----------|------------------|

### Probes for Supervisor
- Q1: ...
- Q2: ...
BODY
  printf '\nTASK:\n%s\n' "$1"
}

_prompt_kimi_k2() {
  cat << 'BODY'
IMPORTANT: You have NO tools, NO file access, and NO function-calling capability available in this session. Do not attempt to call any function or tool (e.g. read_file, Read, etc.) -- any such attempt will fail silently and produce no output. Answer using ONLY the information given below in plain prose/markdown text. If you would normally want to inspect a file, instead reason about it from the description given and clearly mark any such reasoning as an assumption.

Goal: Map every system this task touches and rate the blast radius and reversibility of each connection.

Success means:
  - Every affected system, file, API, schema, and consumer is named
  - Each connection is rated on blast radius and reversibility
  - Silent behavioral changes are named -- things that change without appearing in the diff

Stop when: All integration surfaces are mapped and rated; silent changes are named; rollback is assessed.

You are an integration risk analyst. Find what this change silently affects that the task description does not mention.
This dimension produces an integration surface map and rollback assessment. It does not produce architecture options or failure scenarios.

## Map the integration surface

For each system this task reads, writes, or depends on:
- **Name the connection** -- file path, API endpoint, DB table, queue, cache key, external service
- **Direction** -- reads | writes | both
- **Blast radius**: local (isolated) | service (affects callers) | data-store (persisted change) | user-facing
- **Reversibility**: safe (rollback trivial) | risky (requires migration) | destructive (data loss possible)

## Probe each risk category:

**Behavioral changes (the silent ones)**
- What currently-expected behavior changes for existing callers without them being updated?
- What currently-passing tests become incorrect (false positives) after this change?
- What does a consumer of this code currently rely on that this task changes?

**Schema & contract changes**
- Does this change the shape of any stored data, API response, event payload, or config format?
- Are there consumers of this data outside the scope of this task that receive the changed shape?

**Cascading failures**
- If this component fails, what fails with it?
- Is there a circuit breaker, retry limit, or fallback? YES/NO -- if NO, name the gap.

**Deployment & rollback**
- Can this be deployed without downtime? YES/NO -- if NO, state the migration requirement.
- If this deployment is rolled back, what state is left behind that the rollback does not clean up?

**Ordering & timing**
- Does this task depend on another task or migration that has not yet shipped?
- Does this introduce new timing assumptions (cron schedule, event ordering, deploy-before-migrate)?

## Output format

### Integration Surface
| Component | Direction | Blast Radius | Reversibility | Note |
|-----------|-----------|-------------|---------------|------|

### Silent Changes
Things this task changes that are not named in the task description:
- ...
(if none: explicitly state "none identified")

### Rollback Assessment
Can this be rolled back cleanly? YES/NO.
If NO: what state is left dirty and what is required to clean it?

### Probes for Supervisor
- Q1: ...
- Q2: ...
BODY
  printf '\nTASK:\n%s\n' "$1"
}

_prompt_mistral_large3() {
  cat << 'BODY'
Goal: Map the attack surface this task creates or expands and rate each vector before the code is written.

Success means:
  - Every category below is probed and rated CRITICAL / HIGH / MEDIUM / LOW / N/A
  - Each finding names a concrete attacker payload, not just the category
  - The single most exploitable vector is named explicitly
  - Design controls are proposed (not "add validation" -- specific, buildable controls)

Stop when: All categories below have been probed; every reachable vector is rated; design controls are stated.

You are a security analyst reviewing a planned implementation. Find the attack surface before the code exists so it can be designed out.
This dimension produces an attack surface map and design-level controls. It does not produce architecture options or implementation steps.

## Probe each category -- build the payload, do NOT hand-wave.

**Injection (SQL / NoSQL / OS / template / code)**
- Is any user-controlled input concatenated into a query, command, or rendered template?
- Concrete payloads to test: SQL injection: single-quote UNION SELECT; OS injection: semicolon subshell; SSTI: double-brace arithmetic
- Rate each reachable sink: CRITICAL / HIGH / MEDIUM / LOW

**Authentication & authorization**
- Does this task introduce any unauthenticated entry point?
- Does it rely on caller-supplied identity (user ID in request body/params) without server-side verification?
- IDOR: can user A access user B resources by changing a resource ID? Name the missing ownership check.
- Mass assignment: can the request body set server-controlled fields (role, price, admin flag)?

**Input validation & size limits**
- What are the trust boundaries? Name what is trusted vs. untrusted explicitly.
- Is there an enforced size limit on inputs? What happens above the limit?
- What happens with Unicode, null bytes, path separators, format strings, or control characters?

**Secrets & data exposure**
- Does this task handle credentials, tokens, PII, or sensitive config?
- Can any sensitive value appear in logs, error responses, cache, or client-visible output?

**Cryptography & randomness**
- Does this use any crypto? Is it from a standard library or hand-rolled?
- Is any secret or token derived from user-controlled input or a predictable seed?

**Third-party & supply chain**
- Does this add a new dependency? Name it -- widely used and actively maintained? YES/NO
- Does this call an external service with user-controlled data in the request? Name the service and the controlled fields.

## Output format

### Attack Surface
| Vector | Reachable? | Concrete Payload / Test | Severity |
|--------|-----------|------------------------|----------|

### Most Exploitable Vector
One sentence: the attack most likely to succeed against a naive implementation of this task.

### Design Controls
Specific controls to build in from the start (not "add validation" -- concrete and actionable):
- Control 1: ...
- Control 2: ...
- Control 3: ...

### Probes for Supervisor
- Q1: ...
- Q2: ...
BODY
  printf '\nTASK:\n%s\n' "$1"
}

_prompt_glm5() {
  cat << 'BODY'
Goal: Translate the task into a graded problem definition -- who it affects, what success looks like, and what to explicitly not build.

Success means:
  - A problem statement that names who is affected and what hurts (not what to build)
  - Every implied requirement is graded: clear | assumed | missing
  - 2 measurable success metrics
  - 3+ explicit non-goals that prevent scope creep

Stop when: Problem is stated, all requirements are graded, success metrics are set, non-goals are named.

You are a requirements analyst. Find what the task leaves undefined and prevent scope creep before it starts.
This dimension produces a graded requirements list and problem definition. It does not produce implementation steps or architecture options.

## Execute in order:

**1. Reverse-engineer the problem**
If the task is stated as a solution ("add X"), state the underlying problem X solves.
One or two sentences: who is affected, what hurts today, under what conditions, why it matters now.

**2. Grade each implied requirement**
For every behavior the task implies:
- **clear** -- explicitly stated and unambiguous
- **assumed** -- implied but not stated; name the assumption
- **missing** -- required for the task to be complete but not mentioned anywhere

**3. Set success metrics**
Two metrics that would prove this task worked. Prefer measurable signals; mark qualitative ones explicitly.

**4. Set non-goals**
Three things the task could be interpreted to include but should NOT be built in this increment.

**5. Find the ambiguous scenarios**
Name 2-3 user/caller scenarios the task does not specify but that will definitely arise during implementation.

## Probe each category:

**Scope boundaries**
- What adjacent feature does this task look like it includes but does not?
- What is the minimum viable version that satisfies the actual user need?

**User-facing contract**
- What does the user/caller receive when this works correctly? (Return value, side effect, UI change)
- What does the user/caller receive when it fails? (Error message, fallback, silence)

**Data & state**
- What data is created, modified, or deleted by this task?
- Are there retention, privacy, or ownership requirements on this data?

**Definition of done**
- What does "shipped" mean for this task? (Deployed? Feature-flagged? Tested with users?)
- What does a consumer/caller need to change to use this output?

## Output format

### Problem Statement
One or two sentences: who is affected, what hurts, why now.

### Requirements Grading
| Requirement | Grade | Note |
|-------------|-------|------|
| | clear / assumed / missing | |

### Success Metrics
1. ...
2. ...

### Non-Goals (this increment only)
- We are not building: ...
- We are not building: ...
- We are not building: ...

### Ambiguous Scenarios
| Scenario | What the task says | Gap |
|----------|--------------------|-----|

### Probes for Supervisor
- Q1: ...
- Q2: ...
BODY
  printf '\nTASK:\n%s\n' "$1"
}

_planner_prompt() {
  local label="$1" task="$2" retry="${3:-}"
  case "$label" in
    deepseek-r1)    _prompt_deepseek_r1   "$task" ;;
    qwen3-80b)      _prompt_qwen3_80b     "$task" ;;
    qwen3-coder)    _prompt_qwen3_coder   "$task" ;;
    kimi-k2)        _prompt_kimi_k2       "$task" ;;
    mistral-large3) _prompt_mistral_large3 "$task" ;;
    glm5)           _prompt_glm5          "$task" ;;
    *)              printf 'You are a planning agent. Analyze the task.\n\nTASK:\n%s\n' "$task" ;;
  esac
  if [ "$retry" = retry ]; then
    printf '\nIMPORTANT RETRY: The prior response was unusable tool-call-shaped text. Return the requested analysis now as plain prose/markdown only; do not emit tool syntax.\n'
  fi
}

# Claim the output directory's task marker. mkdir is atomic, so the marker check and
# write are serialized even when independent supervisors start simultaneously.
_claim_task_marker() {
  local task_marker="$out_dir/.plan-committee-task"
  local task_lock="$out_dir/.plan-committee-task.lock"
  local attempts=0 max_attempts=20 previous_task

  while ! mkdir "$task_lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$max_attempts" ]; then
      echo "refusing to use planning output directory: could not acquire task-marker lock" >&2
      return 2
    fi
    sleep 0.1
  done

  # Never erase a different task's claim. A marker-less non-empty directory is
  # unknown/unsafe rather than guessed reusable.
  if [ -f "$task_marker" ]; then
    previous_task="$(cat "$task_marker")"
    if [ "$previous_task" != "$task" ]; then
      rmdir "$task_lock"
      echo "refusing to overwrite planning output for a different task; pass a new --out-dir" >&2
      return 2
    fi
  elif find "$out_dir" -maxdepth 1 \( -type f -o -type l \) \( -name '*.md' -o -name '*.md.raw' -o -name '*.md.jsonl' -o -name '*.md.retry.jsonl' -o -name 'audit.jsonl' \) | grep -q .; then
    rmdir "$task_lock"
    echo "refusing to overwrite unmarked existing planning output; pass a new --out-dir" >&2
    return 2
  fi
  if ! printf '%s' "$task" > "$task_marker"; then
    rmdir "$task_lock"
    echo "refusing to use planning output directory: could not write task marker" >&2
    return 2
  fi
  rmdir "$task_lock"
}

# Run and JSON-classify one planner. Return 0 for clean or self-healed, 1 failed.
_run_planner() {
  local label="$1" model_id="$2" thinking="$3" prompt="$4" out="$5"
  local raw="$out.jsonl" retry_raw="$out.retry.jsonl" retry_prompt status first_run_status retry_run_status
  rm -f "$out.healed" "$out.raw" "$raw" "$retry_raw"
  "$SCRIPT_DIR/run-round.sh" --label "plan-$label" --log "$raw" --timeout "$timeout" --audit "$out_dir/audit.jsonl" -- \
    pi --provider "$PROVIDER" --model "$model_id" --thinking "$thinking" --no-tools --mode json -p "$prompt"
  first_run_status=$?
  "$SCRIPT_DIR/committee-output.py" --input "$raw" --output "$out"; status=$?
  [ "$first_run_status" = 0 ] && [ "$status" = 0 ] && { rm -f "$raw"; return 0; }

  # Preserve the first bad response while retrying with a deliberately changed prompt.
  [ -s "$out" ] && cp "$out" "$out.raw" || cp "$raw" "$out.raw"
  retry_prompt="$(_planner_prompt "$label" "$task" retry)"
  "$SCRIPT_DIR/run-round.sh" --label "plan-$label-retry" --log "$retry_raw" --timeout "$timeout" --audit "$out_dir/audit.jsonl" -- \
    pi --provider "$PROVIDER" --model "$model_id" --thinking "$thinking" --no-tools --mode json -p "$retry_prompt"
  retry_run_status=$?
  "$SCRIPT_DIR/committee-output.py" --input "$retry_raw" --output "$out"; status=$?
  if [ "$retry_run_status" = 0 ] && [ "$status" = 0 ]; then
    touch "$out.healed"
    rm -f "$raw" "$retry_raw"
    return 0
  fi
  [ -s "$out" ] && cp "$out" "$out.raw" || cp "$retry_raw" "$out.raw"
  rm -f "$out"
  return 1
}

# ---- arg parsing ----
task="" out_dir="${SM_LOOP_STATE:-.secondmate}/planning" timeout="${SM_COMMITTEE_TIMEOUT:-300}"
while [ $# -gt 0 ]; do case "$1" in
  --task)    [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; task="$2"; shift 2;;
  --out-dir) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; out_dir="$2"; shift 2;;
  --timeout) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; timeout="$2"; shift 2;;
  --version)
    _pjson="$SCRIPT_DIR/../.claude-plugin/plugin.json"
    version=$(jq -r '.version // empty' "$_pjson" 2>/dev/null)
    [ -n "$version" ] || { echo "could not read version from $_pjson" >&2; exit 1; }
    echo "$version"
    exit 0;;
  --dry-run)
    printf "%-15s %-45s %-6s %s\n" "LABEL" "MODEL" "THINK" "DIMENSION"
    printf "%-15s %-45s %-6s %s\n" "-----" "-----" "-----" "---------"
    for entry in "${PLANNERS[@]}"; do
      IFS='|' read -r _lbl _dim _mid _th <<< "$entry"
      printf "%-15s %-45s %-6s %s\n" "$_lbl" "$_mid" "$_th" "$_dim"
      printf "  cmd: pi --provider %s --model %s --thinking %s --no-tools -p \"<task>\"\n" "$PROVIDER" "$_mid" "$_th"
    done
    exit 0;;
  --list-models)
    printf "%-15s %-45s %-6s %s\n" "LABEL" "MODEL" "THINK" "DIMENSION"
    printf "%-15s %-45s %-6s %s\n" "-----" "-----" "-----" "---------"
    for entry in "${PLANNERS[@]}"; do
      IFS='|' read -r _lbl _dim _mid _th <<< "$entry"
      printf "%-15s %-45s %-6s %s\n" "$_lbl" "$_mid" "$_th" "$_dim"
    done
    exit 0;;
  --selfcheck)
    fails=0
    rc=0; "$0" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || { echo "FAIL: no-task exit $rc (want 2)"; fails=1; }
    rc=0; "$0" --task x --timeout nope >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || { echo "FAIL: non-numeric timeout exit $rc (want 2)"; fails=1; }
    rc=0; "$0" --task x --timeout 0 >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || { echo "FAIL: zero timeout exit $rc (want 2)"; fails=1; }
    _dr="$("$0" --dry-run 2>/dev/null)"
    echo "$_dr" | grep -q "^deepseek-r1" || { echo "FAIL: --dry-run missing planner row"; fails=1; }
    echo "$_dr" | grep -q "cmd: pi" || { echo "FAIL: --dry-run missing cmd line"; fails=1; }
    _lm="$("$0" --list-models 2>/dev/null)"
    echo "$_lm" | grep -q "^deepseek-r1" || { echo "FAIL: --list-models missing expected row"; fails=1; }
    [ "$(echo "$_lm" | wc -l)" -ge 7 ] || { echo "FAIL: --list-models fewer than 7 lines (header+6)"; fails=1; }
    _v="$("$0" --version 2>/dev/null)"
    echo "$_v" | grep -q '\.' || { echo "FAIL: --version output missing a dot"; fails=1; }
    _pjson="$SCRIPT_DIR/../.claude-plugin/plugin.json"
    _pjson_bak="$(mktemp)"; cp "$_pjson" "$_pjson_bak"
    _restore_pjson() { cp "$_pjson_bak" "$_pjson"; rm -f "$_pjson_bak"; }
    trap _restore_pjson EXIT
    echo '{"version":null}' > "$_pjson"
    rc=0; "$0" --version >/dev/null 2>&1 || rc=$?
    trap - EXIT; _restore_pjson
    [ "$rc" = 1 ] || { echo "FAIL: --version null version should exit 1, got $rc"; fails=1; }
    # static PLANNERS contract: 6 entries, 4 pipe-delimited fields each, valid thinking value
    count=0
    for entry in "${PLANNERS[@]}"; do
      count=$((count + 1))
      IFS='|' read -r _lbl _dim _mid _th <<< "$entry"
      [ -n "$_lbl" ] && [ -n "$_mid" ] || { echo "FAIL: empty label or model in entry: $entry"; fails=1; }
      case "$_th" in off|high) ;; *) echo "FAIL: invalid thinking '$_th' in entry: $entry"; fails=1;; esac
    done
    [ "$count" = 6 ] || { echo "FAIL: expected 6 planners, got $count"; fails=1; }
    # _planner_prompt contract: common structure AND dimension-specific markers (bash 3 compatible)
    _dim_markers() { case "$1" in
      deepseek-r1)    echo "Failure Scenarios|Most Dangerous Assumption|Severity | Justification" ;;
      qwen3-80b)      echo "Rabbit hole|Scorecard|Appetite" ;;
      qwen3-coder)    echo "Do Not Hand-Roll|Hardest Step|Error Handling Contract" ;;
      kimi-k2)        echo "Integration Surface|Silent Changes|Rollback Assessment" ;;
      mistral-large3) echo "Attack Surface|Most Exploitable Vector|Design Controls" ;;
      glm5)           echo "Requirements Grading|Non-Goals|Success Metrics" ;;
    esac; }
    for entry in "${PLANNERS[@]}"; do
      IFS='|' read -r _lbl _dim _mid _th <<< "$entry"
      _pp="$(_planner_prompt "$_lbl" "test-task-xyz")"
      [ -n "$_pp" ] || { echo "FAIL: _planner_prompt empty for label: $_lbl"; fails=1; }
      echo "$_pp" | grep -q "test-task-xyz" || { echo "FAIL: _planner_prompt missing task text for label: $_lbl"; fails=1; }
      echo "$_pp" | grep -q "Goal:" || { echo "FAIL: _planner_prompt missing Goal: block for label: $_lbl"; fails=1; }
      echo "$_pp" | grep -q "Probes for Supervisor" || { echo "FAIL: _planner_prompt missing Probes for Supervisor for label: $_lbl"; fails=1; }
      IFS='|' read -r _m1 _m2 _m3 <<< "$(_dim_markers "$_lbl")"
      echo "$_pp" | grep -q "$_m1" || { echo "FAIL: _planner_prompt [$_lbl] missing '$_m1'"; fails=1; }
      echo "$_pp" | grep -q "$_m2" || { echo "FAIL: _planner_prompt [$_lbl] missing '$_m2'"; fails=1; }
      echo "$_pp" | grep -q "$_m3" || { echo "FAIL: _planner_prompt [$_lbl] missing '$_m3'"; fails=1; }
    done
    "$SCRIPT_DIR/committee-output.py" --selfcheck >/dev/null || { echo "FAIL: committee-output real fixture classifier"; fails=1; }
    _qwen_prompt="$(_planner_prompt qwen3-coder test-task-xyz)"
    _kimi_prompt="$(_planner_prompt kimi-k2 test-task-xyz)"
    echo "$_qwen_prompt" | grep -q "NO tools, NO file access" || { echo "FAIL: qwen3-coder missing no-tools hardening"; fails=1; }
    echo "$_kimi_prompt" | grep -q "NO tools, NO file access" || { echo "FAIL: kimi-k2 missing no-tools hardening"; fails=1; }
    # Exercise the actual launch/classify/retry path. The fake pi emits the captured qwen
    # failure on attempt one and clean JSON on the deliberately changed retry prompt.
    _ctmp="$(mktemp -d)"
    cat > "$_ctmp/pi" <<'FAKEPI'
#!/usr/bin/env bash
model=""; prompt=""
while [ $# -gt 0 ]; do
  case "$1" in --model) model="$2"; shift 2;; -p) prompt="$2"; shift 2;; *) shift;; esac
done
echo "$model" >> "$FAKE_CALLS"
if { [ "$model" = qwen.qwen3-coder-next ] && [ "${FAKE_CLEAN_QWEN:-}" != 1 ] && { [ "${FAKE_ALWAYS_BAD:-}" = 1 ] || [[ "$prompt" != *"IMPORTANT RETRY:"* ]]; }; } || { [ "${FAKE_DUAL_BAD:-}" = 1 ] && { [ "$model" = moonshot.kimi-k2-thinking ] || [ "$model" = qwen.qwen3-coder-next ]; } && [[ "$prompt" != *"IMPORTANT RETRY:"* ]]; }; then
  text='I'"'"'ll analyze the bug in `bin/plan-committee.sh` by walking through its concrete implementation steps. Let me first examine the file and related code.

<tool_call>
<function=read_file>
<item path="/Users/eshwar.vijay/secondmate/bin/plan-committee.sh">'
else
  text='### Implementation Steps
1. Classify the final JSON assistant text before accepting it.'
fi
python3 -c 'import json,sys; print(json.dumps({"type":"agent_end","messages":[{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":sys.argv[1]}]}]}))' "$text"
if [ "$model" = qwen.qwen3-coder-next ]; then
  if [ "${FAKE_EXIT_17_FIRST_QWEN:-}" = 1 ] && [[ "$prompt" != *"IMPORTANT RETRY:"* ]]; then exit 17; fi
  if [ "${FAKE_EXIT_17_RETRY_QWEN:-}" = 1 ] && [[ "$prompt" = *"IMPORTANT RETRY:"* ]]; then exit 17; fi
fi
FAKEPI
    chmod +x "$_ctmp/pi"
    FAKE_CALLS="$_ctmp/calls" PATH="$_ctmp:$PATH" "$0" --task fixture-task --out-dir "$_ctmp/out" --timeout 30 >/dev/null 2>&1
    _src=$?
    [ "$_src" = 0 ] || { echo "FAIL: self-healed planner run exited $_src"; fails=1; }
    [ "$(grep -c '^qwen.qwen3-coder-next$' "$_ctmp/calls" 2>/dev/null || true)" = 2 ] || { echo "FAIL: self-healed path did not retry exactly once"; fails=1; }
    [ -f "$_ctmp/out/qwen3-coder.md.healed" ] || { echo "FAIL: self-healed planner was not visibly marked"; fails=1; }
    # Both tool-call-hardened models can independently need one retry; one
    # model's failure must not consume the other's retry budget.
    FAKE_CALLS="$_ctmp/calls-dual" FAKE_DUAL_BAD=1 PATH="$_ctmp:$PATH" "$0" --task dual-retry-fixture --out-dir "$_ctmp/dual" --timeout 30 >/dev/null 2>&1
    _src=$?
    [ "$_src" = 0 ] || { echo "FAIL: dual self-healed planner run exited $_src"; fails=1; }
    for _model in moonshot.kimi-k2-thinking qwen.qwen3-coder-next; do
      [ "$(grep -c "^$_model$" "$_ctmp/calls-dual" 2>/dev/null || true)" = 2 ] || { echo "FAIL: $_model did not retry exactly once in dual fixture"; fails=1; }
    done
    [ -f "$_ctmp/dual/kimi-k2.md.healed" ] || { echo "FAIL: kimi-k2 was not marked healed in dual fixture"; fails=1; }
    [ -f "$_ctmp/dual/qwen3-coder.md.healed" ] || { echo "FAIL: qwen3-coder was not marked healed in dual fixture"; fails=1; }
    for _model in us.deepseek.r1-v1:0 qwen.qwen3-next-80b-a3b mistral.mistral-large-3-675b-instruct zai.glm-5; do
      [ "$(grep -c "^$_model$" "$_ctmp/calls-dual" 2>/dev/null || true)" = 1 ] || { echo "FAIL: untouched $_model was not invoked exactly once in dual fixture"; fails=1; }
    done
    for _label in deepseek-r1 qwen3-80b mistral-large3 glm5; do
      [ ! -f "$_ctmp/dual/$_label.md.healed" ] || { echo "FAIL: untouched $_label was incorrectly marked healed"; fails=1; }
    done
    # A valid response paired with a failed pi process must use its retry.
    FAKE_CALLS="$_ctmp/calls-first-exit" FAKE_CLEAN_QWEN=1 FAKE_EXIT_17_FIRST_QWEN=1 PATH="$_ctmp:$PATH" "$0" --task first-exit-fixture --out-dir "$_ctmp/first-exit" --timeout 30 >/dev/null 2>&1
    _src=$?
    [ "$_src" = 0 ] || { echo "FAIL: first-attempt pi exit fixture exited $_src"; fails=1; }
    [ "$(grep -c '^qwen.qwen3-coder-next$' "$_ctmp/calls-first-exit" 2>/dev/null || true)" = 2 ] || { echo "FAIL: first-attempt pi exit did not trigger exactly one qwen retry"; fails=1; }
    [ -f "$_ctmp/first-exit/qwen3-coder.md.healed" ] || { echo "FAIL: first-attempt pi exit was not visibly self-healed"; fails=1; }
    # A failed pi process on the retry is not self-healed, even when its JSON is valid.
    FAKE_CALLS="$_ctmp/calls-retry-exit" FAKE_CLEAN_QWEN=1 FAKE_EXIT_17_FIRST_QWEN=1 FAKE_EXIT_17_RETRY_QWEN=1 PATH="$_ctmp:$PATH" "$0" --task retry-exit-fixture --out-dir "$_ctmp/retry-exit" --timeout 30 >/dev/null 2>&1
    _src=$?
    [ "$_src" != 0 ] || { echo "FAIL: retry-attempt pi exit did not fail aggregate exit"; fails=1; }
    [ "$(grep -c '^qwen.qwen3-coder-next$' "$_ctmp/calls-retry-exit" 2>/dev/null || true)" = 2 ] || { echo "FAIL: retry-attempt pi exit did not invoke qwen exactly twice"; fails=1; }
    [ ! -s "$_ctmp/retry-exit/qwen3-coder.md" ] || { echo "FAIL: failed retry-attempt pi exit left planner output looking clean"; fails=1; }
    [ ! -f "$_ctmp/retry-exit/qwen3-coder.md.healed" ] || { echo "FAIL: retry-attempt pi exit was incorrectly marked healed"; fails=1; }
    FAKE_CALLS="$_ctmp/calls-bad" FAKE_ALWAYS_BAD=1 PATH="$_ctmp:$PATH" "$0" --task failed-fixture --out-dir "$_ctmp/bad" --timeout 30 >/dev/null 2>&1
    _src=$?
    [ "$_src" != 0 ] || { echo "FAIL: doubly garbled planner did not fail aggregate exit"; fails=1; }
    [ -s "$_ctmp/bad/qwen3-coder.md.raw" ] || { echo "FAIL: failed planner did not preserve raw output"; fails=1; }
    FAKE_CALLS="$_ctmp/calls-collision" PATH="$_ctmp:$PATH" "$0" --task other-task --out-dir "$_ctmp/out" --timeout 30 >/dev/null 2>&1
    _src=$?
    [ "$_src" = 2 ] || { echo "FAIL: output-directory task collision exit $_src (want 2)"; fails=1; }
    # An unmarked raw diagnostic alone must prevent a different task from
    # destroying evidence from a failed committee.
    mkdir -p "$_ctmp/raw-only"
    printf 'retained diagnostic' > "$_ctmp/raw-only/qwen3-coder.md.raw"
    _raw_err="$(PATH="$_ctmp:$PATH" "$0" --task other-raw-task --out-dir "$_ctmp/raw-only" --timeout 30 2>&1)"
    _src=$?
    [ "$_src" = 2 ] || { echo "FAIL: raw-only output collision exit $_src (want 2)"; fails=1; }
    echo "$_raw_err" | grep -q "refusing to overwrite unmarked existing planning output" || { echo "FAIL: raw-only output collision did not report unmarked output"; fails=1; }
    [ "$(cat "$_ctmp/raw-only/qwen3-coder.md.raw")" = "retained diagnostic" ] || { echo "FAIL: raw-only output collision modified diagnostic"; fails=1; }
    # Even an empty diagnostic is evidence of a prior failed committee.
    mkdir -p "$_ctmp/raw-empty"
    : > "$_ctmp/raw-empty/qwen3-coder.md.raw"
    _empty_raw_err="$(PATH="$_ctmp:$PATH" "$0" --task other-empty-raw-task --out-dir "$_ctmp/raw-empty" --timeout 30 2>&1)"
    _src=$?
    [ "$_src" = 2 ] || { echo "FAIL: empty raw-only output collision exit $_src (want 2)"; fails=1; }
    echo "$_empty_raw_err" | grep -q "refusing to overwrite unmarked existing planning output" || { echo "FAIL: empty raw-only output collision did not report unmarked output"; fails=1; }
    [ -f "$_ctmp/raw-empty/qwen3-coder.md.raw" ] && [ ! -s "$_ctmp/raw-empty/qwen3-coder.md.raw" ] || { echo "FAIL: empty raw-only output collision modified diagnostic"; fails=1; }
    # A protected-name symlink must not be followed and overwrite its target.
    mkdir -p "$_ctmp/symlink-only"
    printf 'external evidence' > "$_ctmp/external-evidence"
    ln -s "$_ctmp/external-evidence" "$_ctmp/symlink-only/qwen3-coder.md"
    _symlink_err="$(PATH="$_ctmp:$PATH" "$0" --task other-symlink-task --out-dir "$_ctmp/symlink-only" --timeout 30 2>&1)"
    _src=$?
    [ "$_src" = 2 ] || { echo "FAIL: symlink-only output collision exit $_src (want 2)"; fails=1; }
    echo "$_symlink_err" | grep -q "refusing to overwrite unmarked existing planning output" || { echo "FAIL: symlink-only output collision did not report unmarked output"; fails=1; }
    [ "$(cat "$_ctmp/external-evidence")" = "external evidence" ] || { echo "FAIL: symlink-only output collision modified external evidence"; fails=1; }
    # The shared audit trail is also evidence of an unmarked prior committee.
    mkdir -p "$_ctmp/audit-only"
    printf 'retained audit record' > "$_ctmp/audit-only/audit.jsonl"
    _audit_err="$(PATH="$_ctmp:$PATH" "$0" --task other-audit-task --out-dir "$_ctmp/audit-only" --timeout 30 2>&1)"
    _src=$?
    [ "$_src" = 2 ] || { echo "FAIL: audit-only output collision exit $_src (want 2)"; fails=1; }
    echo "$_audit_err" | grep -q "refusing to overwrite unmarked existing planning output" || { echo "FAIL: audit-only output collision did not report unmarked output"; fails=1; }
    [ "$(cat "$_ctmp/audit-only/audit.jsonl")" = "retained audit record" ] || { echo "FAIL: audit-only output collision modified audit"; fails=1; }
    # Force two independently launched calls through the marker-claim path at
    # the same time. The delayed real find widens the old check-then-write
    # race; atomic mkdir must admit exactly one task.
    _real_find="$(command -v find)"
    cat > "$_ctmp/find" <<'FAKEFIND'
#!/usr/bin/env bash
sleep "${FAKE_FIND_DELAY:-0}"
exec "$FAKE_REAL_FIND" "$@"
FAKEFIND
    chmod +x "$_ctmp/find"
    FAKE_CALLS="$_ctmp/calls-concurrent" FAKE_FIND_DELAY=1 FAKE_REAL_FIND="$_real_find" PATH="$_ctmp:$PATH" "$0" --task concurrent-a --out-dir "$_ctmp/concurrent" --timeout 30 >/dev/null 2>&1 &
    _concurrent_a=$!
    FAKE_CALLS="$_ctmp/calls-concurrent" FAKE_FIND_DELAY=1 FAKE_REAL_FIND="$_real_find" PATH="$_ctmp:$PATH" "$0" --task concurrent-b --out-dir "$_ctmp/concurrent" --timeout 30 >/dev/null 2>&1 &
    _concurrent_b=$!
    wait "$_concurrent_a"; _concurrent_a_rc=$?
    wait "$_concurrent_b"; _concurrent_b_rc=$?
    if ! { [ "$_concurrent_a_rc" = 0 ] && [ "$_concurrent_b_rc" = 2 ]; } && ! { [ "$_concurrent_a_rc" = 2 ] && [ "$_concurrent_b_rc" = 0 ]; }; then
      echo "FAIL: concurrent output claims exited $_concurrent_a_rc and $_concurrent_b_rc (want one 0 and one 2)"
      fails=1
    fi
    _concurrent_task="$(cat "$_ctmp/concurrent/.plan-committee-task" 2>/dev/null || true)"
    case "$_concurrent_task" in concurrent-a|concurrent-b) ;; *) echo "FAIL: concurrent output claim wrote unexpected marker '$_concurrent_task'"; fails=1;; esac
    # A held claim must fail closed after the bounded wait rather than proceed.
    mkdir -p "$_ctmp/locked/.plan-committee-task.lock"
    _locked_err="$("$0" --task locked-task --out-dir "$_ctmp/locked" --timeout 30 2>&1)"
    _src=$?
    [ "$_src" = 2 ] || { echo "FAIL: held task-marker lock exit $_src (want 2)"; fails=1; }
    echo "$_locked_err" | grep -q "could not acquire task-marker lock" || { echo "FAIL: held task-marker lock did not report acquisition failure"; fails=1; }
    rm -rf "$_ctmp"
    [ "$fails" = 0 ] && echo ok; exit "$fails";;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$task" ] || { echo "need --task TEXT" >&2; exit 2; }
case "$timeout" in ''|*[!0-9]*) echo "--timeout must be a positive integer (seconds)" >&2; exit 2;; esac
[ "$timeout" -gt 0 ] || { echo "--timeout must be a positive integer (seconds)" >&2; exit 2; }

mkdir -p "$out_dir"
_claim_task_marker || exit $?

# ---- launch all planners in parallel ----
pids=(); labels=(); outs=()
for entry in "${PLANNERS[@]}"; do
  IFS='|' read -r label dimension model_id thinking <<< "$entry"
  out="$out_dir/$label.md"
  prompt="$(_planner_prompt "$label" "$task")"
  _run_planner "$label" "$model_id" "$thinking" "$prompt" "$out" &
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
  if [ -f "$f.healed" ]; then
    echo "  ~ ${labels[$i]} ($(wc -l < "$f") lines; self-healed after retry) -> $f"
  elif [ -f "$f" ] && [ -s "$f" ]; then
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
