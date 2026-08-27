#!/usr/bin/env bash
# launch-checker.sh -- always edit-locked cross-model checker. --exclude-tools edit,write is hardcoded so a
# checker can never mutate the maker's work. Layers, freshest LAST (= most authoritative):
#   1. base checker discipline (checker-prompt.md)   2. optional role lens(es)   3. verdict envelope
#   4. your per-task addendum (the standing spec)     5. the LIVE layer for THIS round (auto-fresh, can't go stale)
# The LIVE layer auto-gathers `git diff <base>..HEAD` (pruned) + a prior-round verdict file, plus your focus note.
#   launch-checker.sh --addendum-text "..." [--lens redteam,qa] [--diff-base REF [--repo DIR]] [--live-text "..."] [--model M] [--thinking L] -- [extra args]
# Env: SM_CHECKER_HARNESS(pi) SM_CHECKER_PROVIDER(amazon-bedrock) SM_CHECKER_MODEL(global.openai.gpt-5.6-terra)
#      SM_CHECKER_THINKING(high) SM_CHECKER_PROMPT(<plugin>/bin/checker-prompt.md)
#      SM_LAST_VERDICT (default $SM_LOOP_STATE/last-verdict.md) -- prior round's checker output, auto-injected if present
#      SM_CHECKER_DRYRUN=1 -- print the assembled harness command instead of running it (inspection / --selfcheck)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--selfcheck" ]; then
  fails=0
  rc=0; "$0" -- -p q >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: no-addendum exit $rc (want 2)"; fails=1; }
  rc=0; "$0" --addendum-text x --lens __nope__ -- -p q >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: unknown-lens exit $rc (want 2)"; fails=1; }
  rc=0; SM_CHECKER_PROMPT=/nonexistent-xyz "$0" --addendum-text x -- -p q >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || { echo "FAIL: missing-prompt exit $rc (want 1)"; fails=1; }
  # LIVE layer: a real git diff + focus note must land in the assembled prompt, auto-fresh (dry-run: no harness needed).
  t="$(mktemp -d)"; git -C "$t" init -q -b main; git -C "$t" config user.email a@a; git -C "$t" config user.name a
  echo base > "$t/f"; git -C "$t" add -A; git -C "$t" commit -qm c1
  echo CHANGED-LINE-XYZ >> "$t/f"; git -C "$t" commit -qam c2
  out="$(SM_CHECKER_DRYRUN=1 "$0" --addendum-text spec --diff-base main~1 --repo "$t" --live-text "focus verify boundary" -- -p q 2>&1)" || { echo "FAIL: dryrun errored"; fails=1; }
  echo "$out" | grep -aq 'CHANGED-LINE-XYZ'          || { echo "FAIL: live diff not injected"; fails=1; }
  echo "$out" | grep -aq 'focus verify boundary'      || { echo "FAIL: focus note not injected"; fails=1; }
  echo "$out" | grep -aq 'THIS review round'          || { echo "FAIL: live header missing"; fails=1; }
  rm -rf "$t"
  [ "$fails" = 0 ] && echo ok; exit "$fails"
fi

harness="${SM_CHECKER_HARNESS:-pi}"
provider="${SM_CHECKER_PROVIDER:-amazon-bedrock}"
model="${SM_CHECKER_MODEL:-global.openai.gpt-5.6-terra}"
thinking="${SM_CHECKER_THINKING:-high}"
base_prompt="${SM_CHECKER_PROMPT:-$SCRIPT_DIR/checker-prompt.md}"
addendum_file="" addendum_text=""; lenses=()
diff_base="" repo_dir="" live_text="" live_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --addendum) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; addendum_file="$2"; shift 2;;
    --addendum-text) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; addendum_text="$2"; shift 2;;
    --lens) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; lenses+=("$2"); shift 2;;
    --diff-base) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; diff_base="$2"; shift 2;;
    --repo) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; repo_dir="$2"; shift 2;;
    --live-text) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; live_text="$2"; shift 2;;
    --live-file) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; live_file="$2"; shift 2;;
    --model) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; case "$2" in terra|sol|luna) model="global.openai.gpt-5.6-$2";; *) model="$2";; esac; shift 2;;
    --thinking) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; thinking="$2"; shift 2;;
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

# Optional role lenses (--lens redteam,qa,...): specialized disciplines from bin/lenses/, on top of the base. Fail loud on unknown.
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

# Verdict envelope + report contract (static): injected if present so the checker always emits a machine-branchable block.
envelope="$SCRIPT_DIR/checker-envelope.md"
envelope_arg=()
[ -f "$envelope" ] && envelope_arg=(--append-system-prompt "$(cat "$envelope")")

# LIVE layer (dynamic, THIS round) -- freshest, injected LAST. Auto-gathered so it can't go stale:
#   git diff <base>..HEAD (pruned), the prior round's verdict if the loop saved one, and the supervisor's focus note.
repo_dir="${repo_dir:-$PWD}"
live=""
if [ -n "$diff_base" ]; then
  if git -C "$repo_dir" rev-parse --verify -q "$diff_base^{commit}" >/dev/null 2>&1; then
    live+="### Diff under review -- git diff $diff_base..HEAD (live, this round)"$'\n'
    live+="$(git -C "$repo_dir" diff --stat "$diff_base"..HEAD 2>/dev/null)"$'\n\n'
    live+="$(git -C "$repo_dir" diff "$diff_base"..HEAD 2>/dev/null | "$SCRIPT_DIR/prune-output.sh")"$'\n\n'
  else
    echo "warning: --diff-base '$diff_base' not resolvable in $repo_dir; skipping live diff" >&2
  fi
fi
_prior="${SM_LAST_VERDICT:-${SM_LOOP_STATE:-.secondmate}/last-verdict.md}"
[ -f "$_prior" ] && live+="### Prior round verdict -- resolve or re-confirm each item; do not re-litigate settled ones"$'\n'"$(cat "$_prior")"$'\n\n'
if [ -n "$live_file" ]; then
  [ -f "$live_file" ] || { echo "live-file not found: $live_file" >&2; exit 1; }
  live_text="$(cat "$live_file")${live_text:+
$live_text}"
fi
[ -n "$live_text" ] && live+="### Focus for THIS round (supervisor)"$'\n'"$live_text"$'\n'
live_args=()
[ -n "$live" ] && live_args=(--append-system-prompt "## LIVE -- current state for THIS review round
This reflects exactly what changed now and what the prior round concluded; it is the freshest context. Where it conflicts with the generic guidance above, follow THIS.

$live")

# Assemble the harness command (bash-3.2-safe empty-array guards).
args=(--provider "$provider" --model "$model" --thinking "$thinking" --exclude-tools edit,write)
args+=(--append-system-prompt "$(cat "$base_prompt")")
[ "${#lens_args[@]}" -gt 0 ] && args+=("${lens_args[@]}")
[ "${#envelope_arg[@]}" -gt 0 ] && args+=("${envelope_arg[@]}")
args+=(--append-system-prompt "$addendum")
[ "${#live_args[@]}" -gt 0 ] && args+=("${live_args[@]}")

# Inspect mode: print the assembled command (one arg per line) instead of running it (used by --selfcheck / debugging).
if [ "${SM_CHECKER_DRYRUN:-}" = 1 ]; then
  printf 'HARNESS: %s\n' "$harness"
  printf 'ARG: %s\n' "${args[@]}" "$@"
  exit 0
fi

# No harness installed? Signal the supervisor to use the in-session Claude checker fallback (exit 3), not a raw crash.
if ! command -v "$harness" >/dev/null 2>&1; then
  echo "SM_NO_CHECKER_HARNESS: '$harness' not found. Fall back to an in-session checker: spawn a Claude sub-agent on a DIFFERENT model than the maker, review-only, with $base_prompt plus the verdict envelope plus the diff, then run its output through verdict.py. For a stronger cross-vendor check install a harness: npm install -g @earendil-works/pi-coding-agent" >&2
  exit 3
fi

# --exclude-tools edit,write is NOT optional: it makes the checker physically read-only.
exec "$harness" "${args[@]}" "$@"
