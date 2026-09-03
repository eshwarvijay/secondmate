#!/usr/bin/env bash
# log-round.sh -- append one structured metrics record per checker round to an append-only JSONL ledger,
# so the supervisor can later query round counts, verdict outcomes, and recurring finding categories
# across tasks instead of only having free-text prose in audit/flow.md and audit/decision.md.
# Never rewrites prior lines -- same "append, never rewrite" convention as those files.
#
#   log-round.sh --task ID --round N --maker claude|pi --verdict pass|fail|error|refused \
#     [--tag TAG]... [--cost N] [--duration N]
#   log-round.sh --selfcheck
#
# Ledger path: $SM_METRICS_LEDGER, else ./audit/metrics.jsonl. --tag is repeatable (finding categories
# the caller supplies, e.g. scope-creep, fake-test, not-committed, real-bug -- no auto-classification).
# --cost/--duration are optional freeform numbers the caller already has (e.g. from a herdr pane's own
# cost/elapsed display) -- this script never scrapes or parses herdr output itself.
set -euo pipefail

LEDGER="${SM_METRICS_LEDGER:-audit/metrics.jsonl}"

# Validates --cost/--duration without ever interpolating the caller-supplied string into executed Python
# source -- the value travels as an argv element (sys.argv[1]), never string-built into -c code, so it
# can't inject Python regardless of content. Also rejects nan/inf/-inf: float() accepts them but they
# serialize to literal NaN/Infinity tokens, which are not valid JSON.
_is_finite_number() {
  python3 -c '
import sys, math
try:
    v = float(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if math.isfinite(v) else 1)
' "$1"
}

if [ "${1:-}" = "--selfcheck" ]; then
  t="$(mktemp -d)"; fails=0
  L="$t/metrics.jsonl"

  SM_METRICS_LEDGER="$L" "$0" --task demo-task --round 1 --maker claude --verdict pass \
    --tag real-bug --tag scope-creep --cost 0.42 --duration 118.5
  SM_METRICS_LEDGER="$L" "$0" --task demo-task --round 2 --maker pi --verdict fail --tag fake-test

  [ "$(wc -l <"$L" | tr -d ' ')" = "2" ] || { echo "FAIL: expected 2 lines, got $(wc -l <"$L")"; fails=1; }

  python3 - "$L" <<'EOF' || fails=1
import json, sys
lines = open(sys.argv[1]).read().splitlines()
r1 = json.loads(lines[0]); r2 = json.loads(lines[1])
assert r1["task"] == "demo-task" and r1["round"] == 1, "round 1 fields wrong"
assert r1["maker"] == "claude" and r1["verdict"] == "pass", "round 1 maker/verdict wrong"
assert r1["tags"] == ["real-bug", "scope-creep"], f"round 1 tags wrong: {r1['tags']}"
assert r1["cost"] == 0.42 and r1["duration"] == 118.5, "round 1 cost/duration wrong"
assert "ts" in r1 and r1["ts"], "round 1 missing timestamp"
assert r2["round"] == 2 and r2["maker"] == "pi" and r2["verdict"] == "fail", "round 2 fields wrong"
assert "cost" not in r2 and "duration" not in r2, "round 2 optional fields should be absent, not null"
assert r1["task"] == "demo-task", "first line mutated by second append -- not append-only"
EOF
  [ "$fails" = 0 ] || echo "FAIL: appended record content wrong"

  before="$(cat "$L")"
  rc=0; SM_METRICS_LEDGER="$L" "$0" --task x --round 1 --maker bogus --verdict pass >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: bogus --maker should be rejected"; fails=1; }
  rc=0; SM_METRICS_LEDGER="$L" "$0" --task x --round 1 --maker claude --verdict bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: bogus --verdict should be rejected"; fails=1; }
  rc=0; SM_METRICS_LEDGER="$L" "$0" --task x --round notanum --maker claude --verdict pass >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: non-numeric --round should be rejected"; fails=1; }
  rc=0; SM_METRICS_LEDGER="$L" "$0" --round 1 --maker claude --verdict pass >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: missing --task should be rejected"; fails=1; }
  [ "$(cat "$L")" = "$before" ] || { echo "FAIL: a rejected call still wrote to the ledger"; fails=1; }

  d="$t/nested/dir"
  SM_METRICS_LEDGER="$d/metrics.jsonl" "$0" --task y --round 1 --maker pi --verdict error >/dev/null
  [ -f "$d/metrics.jsonl" ] || { echo "FAIL: did not create missing parent directory"; fails=1; }

  # finding #1: a --cost value crafted to look like Python source must be rejected, not executed --
  # canary file proves it was never run as code, not just that the command errored.
  canary="$t/INJECTED"
  rc=0; SM_METRICS_LEDGER="$L" "$0" --task x --round 1 --maker claude --verdict pass \
    --cost "0');import pathlib;pathlib.Path('$canary').touch();print('0" >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: crafted --cost should be rejected"; fails=1; }
  [ ! -f "$canary" ] || { echo "FAIL: crafted --cost executed as Python (injection)"; fails=1; }

  # finding #2: nan/inf are valid floats but not valid JSON tokens -- must be rejected like any bad input.
  for bad in nan inf -inf Infinity; do
    rc=0; SM_METRICS_LEDGER="$L" "$0" --task x --round 1 --maker claude --verdict pass --cost "$bad" >/dev/null 2>&1 || rc=$?
    [ "$rc" != 0 ] || { echo "FAIL: --cost $bad should be rejected (non-finite)"; fails=1; }
    rc=0; SM_METRICS_LEDGER="$L" "$0" --task x --round 1 --maker claude --verdict pass --duration "$bad" >/dev/null 2>&1 || rc=$?
    [ "$rc" != 0 ] || { echo "FAIL: --duration $bad should be rejected (non-finite)"; fails=1; }
  done

  # finding #3: a tag with spaces/quotes/shell-metacharacters must survive intact through argv -> JSON.
  weird='tag with spaces "and quotes" & special;chars'
  L2="$t/weird.jsonl"
  SM_METRICS_LEDGER="$L2" "$0" --task w --round 1 --maker pi --verdict pass --tag "$weird" >/dev/null
  python3 - "$L2" "$weird" <<'EOF' || fails=1
import json, sys
line, expected = open(sys.argv[1]).read().strip(), sys.argv[2]
rec = json.loads(line)
assert rec["tags"] == [expected], f"weird tag mangled: {rec['tags']!r} != {[expected]!r}"
EOF
  [ "$fails" = 0 ] || echo "FAIL: weird-tag content not preserved exactly"

  rm -rf "$t"; [ "$fails" = 0 ] && echo ok; exit "$fails"
fi

task="" round="" maker="" verdict="" cost="" duration=""
tags=()
while [ $# -gt 0 ]; do case "$1" in
  --task) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; task="$2"; shift 2;;
  --round) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; round="$2"; shift 2;;
  --maker) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; maker="$2"; shift 2;;
  --verdict) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; verdict="$2"; shift 2;;
  --tag) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; tags+=("$2"); shift 2;;
  --cost) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; cost="$2"; shift 2;;
  --duration) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; duration="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$task" ] || { echo "missing --task" >&2; exit 2; }
[ -n "$round" ] || { echo "missing --round" >&2; exit 2; }
[ -n "$maker" ] || { echo "missing --maker" >&2; exit 2; }
[ -n "$verdict" ] || { echo "missing --verdict" >&2; exit 2; }
case "$round" in ''|*[!0-9]*) echo "invalid --round: $round (want a non-negative integer)" >&2; exit 2;; esac
case "$maker" in claude|pi) ;; *) echo "invalid --maker: $maker (want claude|pi)" >&2; exit 2;; esac
case "$verdict" in pass|fail|error|refused) ;; *) echo "invalid --verdict: $verdict (want pass|fail|error|refused)" >&2; exit 2;; esac
if [ -n "$cost" ]; then _is_finite_number "$cost" || { echo "invalid --cost: $cost (want a finite number)" >&2; exit 2; }; fi
if [ -n "$duration" ]; then _is_finite_number "$duration" || { echo "invalid --duration: $duration (want a finite number)" >&2; exit 2; }; fi

mkdir -p "$(dirname "$LEDGER")"
python3 - "$task" "$round" "$maker" "$verdict" "$cost" "$duration" "${tags[@]:-}" <<'EOF' >> "$LEDGER"
import json, sys, time
task, round_, maker, verdict, cost, duration, *tags = sys.argv[1:]
rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "task": task, "round": int(round_),
       "maker": maker, "verdict": verdict, "tags": [t for t in tags if t]}
if cost:
    rec["cost"] = float(cost)
if duration:
    rec["duration"] = float(duration)
print(json.dumps(rec))
EOF
