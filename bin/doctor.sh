#!/usr/bin/env bash
# doctor.sh -- secondmate preflight + self-heal. Detects every requirement and (with --heal) installs the ones
# it knows how to; the human only APPROVES each action, never hunts for setup steps.
#   doctor.sh            # report; exit 0 only if CORE + a checker harness are present
#   doctor.sh --json     # machine-readable status (consumed by /fm-doctor)
#   doctor.sh --heal [--yes]   # install each missing item that has a known fix (confirm each unless --yes)
#   doctor.sh --selfcheck
#
# Maintainer: the COMPANIONS block below is the one place to edit when you distribute your own
# loop-task / adhd / herdr skills — fill in the marketplace/URL fix command and colleagues get them too.
set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
brewable() { if have brew; then echo "brew install $1"; elif have apt-get; then echo "sudo apt-get install -y $1"; else echo ""; fi; }
plugin_present() { claude plugin list 2>/dev/null | grep -q "$1@" || [ -d "$HOME/.claude/plugins/marketplaces/$1" ]; }
skill_present() { [ -d "$HOME/.claude/skills/$1" ] || find "$HOME/.claude/plugins/marketplaces" -maxdepth 4 -type d -name "$1" 2>/dev/null | grep -q .; }

ROWS=""; core_missing=0; checker_missing=0
add() { # status name category fix
  ROWS+="$1|$2|$3|$4"$'\n'
  if [ "$1" = MISSING ]; then
    [ "$3" = core ] && core_missing=$((core_missing + 1))
    [ "$3" = checker ] && checker_missing=$((checker_missing + 1))
  fi
}

detect() {
  local h="${FM_CHECKER_HARNESS:-pi}"
  # CORE — the loop's non-model machinery
  for t in git gh python3; do have "$t" && add OK "$t" core "" || add MISSING "$t" core "$(brewable "$t")"; done
  # CHECKER RUNTIME — cross-model check + reasoning one-shots
  if have "$h"; then add OK "$h (checker/reason harness)" checker ""
  else add MISSING "$h (checker/reason harness)" checker "npm install -g @earendil-works/pi-coding-agent"; fi
  # COMPANIONS — recommended; enhance the workflow (edit fixes to match what you distribute)
  have herdr && add OK "herdr (multi-pane orchestration)" companion "" || add MISSING "herdr (multi-pane orchestration)" companion "brew install herdr"
  plugin_present ponytail && add OK "ponytail (complexity lens plugin)" companion "" || add MISSING "ponytail (complexity lens plugin)" companion "claude plugin marketplace add DietrichGebert/ponytail && claude plugin install ponytail@ponytail --yes"
  # loop-task ships bundled with this plugin (commands/loop-task.md) — no external install needed.
  skill_present adhd && add OK "adhd (divergent ideation)" companion "" || add MISSING "adhd (divergent ideation)" companion "claude plugin marketplace add UditAkhourii/adhd && claude plugin install adhd@adhd --yes"
}

emit_json() {
  printf '['; local first=1
  while IFS='|' read -r st name cat fix; do
    [ -z "$name" ] && continue
    [ $first -eq 0 ] && printf ','; first=0
    fix=${fix//\\/\\\\}; fix=${fix//\"/\\\"}
    printf '{"name":"%s","status":"%s","category":"%s","fix":"%s"}' "$name" "$st" "$cat" "$fix"
  done <<< "$ROWS"
  printf ']\n'
}

emit_table() {
  echo "secondmate doctor"
  echo "----------------------------------------------------------------------"
  while IFS='|' read -r st name cat fix; do
    [ -z "$name" ] && continue
    local mark="[ok]"; [ "$st" = MISSING ] && mark="[!!]"
    printf '%-4s %-38s %-9s %s\n' "$mark" "$name" "$cat" "$fix"
  done <<< "$ROWS"
  echo "----------------------------------------------------------------------"
  echo "note: cross-model checking also needs a 2nd model family + credentials for your harness"
  echo "      (defaults: amazon-bedrock GPT-5.6 / DeepSeek-R1). Set FM_CHECKER_* / FM_REASON_* to yours."
  if [ "$core_missing" -eq 0 ] && [ "$checker_missing" -eq 0 ]; then echo "STATUS: ready (core + checker present)"
  else echo "STATUS: not ready ($core_missing core, $checker_missing checker missing) — run: doctor.sh --heal"; fi
}

heal() {
  local yes="$1"
  while IFS='|' read -r st name cat fix; do
    [ "$st" = MISSING ] || continue
    if [ -z "$fix" ]; then echo "SKIP  $name — no known auto-fix; provide its source (see README) and set the matching FM_* var"; continue; fi
    if [ "$yes" = 1 ]; then echo ">> healing $name: $fix"; bash -c "$fix" || echo "   (failed — do it manually: $fix)"
    else
      printf 'Fix %s via: %s\n  proceed? [y/N] ' "$name" "$fix"; read -r ans
      case "$ans" in y|Y) bash -c "$fix" || echo "   (failed — do it manually: $fix)";; *) echo "   skipped";; esac
    fi
  done <<< "$ROWS"
}

# --- selfcheck (no installs) ---
if [ "${1:-}" = "--selfcheck" ]; then
  out="$("$0" --json)" || { echo "FAIL: --json errored"; exit 1; }
  python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$out" || { echo "FAIL: --json not valid JSON"; exit 1; }
  "$0" >/dev/null 2>&1; rc=$?; [ "$rc" = 0 ] || [ "$rc" = 1 ] || { echo "FAIL: unexpected exit $rc"; exit 1; }
  echo ok; exit 0
fi

detect
case "${1:-}" in
  --json) emit_json;;
  --heal) [ "${2:-}" = "--yes" ] && heal 1 || heal 0; echo; emit_table;;
  ""|--report) emit_table;;
  *) echo "usage: doctor.sh [--json|--heal [--yes]|--selfcheck]" >&2; exit 2;;
esac
[ "$core_missing" -eq 0 ] && [ "$checker_missing" -eq 0 ]
