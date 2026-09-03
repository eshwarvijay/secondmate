#!/usr/bin/env bash
# doctor.sh -- secondmate preflight + self-heal. Detects every requirement and (with --heal) installs the ones
# it knows how to; the human only APPROVES each action, never hunts for setup steps.
#   doctor.sh            # report; exit 0 only if CORE + a checker harness are present
#   doctor.sh --json     # machine-readable status (consumed by /secondmate-doctor)
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

# read plugin version relative to script location (compute before selfcheck branch)
# resolve real script path through symlinks using readlink -f (GNU) or realpath (BSD)
_real_script=""
if [ -n "${BASH_SOURCE[0]}" ]; then
  if command -v readlink >/dev/null 2>&1; then
    if readlink -f /dev/null >/dev/null 2>&1; then
      _real_script=$(readlink -f "${BASH_SOURCE[0]}")
    elif realpath --version 2>&1 | grep -q GNU; then
      _real_script=$(realpath "${BASH_SOURCE[0]}")
    else
      # portable fallback: follow symlinks manually
      _p="${BASH_SOURCE[0]}"
      while [ -L "$_p" ]; do
        _p=$(readlink "$_p")
        # handle relative symlinks
        case "$_p" in
          /*) ;;
          *) _p="$(dirname "${BASH_SOURCE[0]}")/$_p" ;;
        esac
      done
      _real_script=$(cd "$(dirname "$_p")" && pwd)/$(basename "$_p")
    fi
  fi
fi
if [ -z "$_real_script" ]; then
  _real_script="${BASH_SOURCE[0]}"
fi
script_dir="$(cd "$(dirname "$_real_script")" && pwd)"
version_line=""
# plugin.json lives in script_dir's parent (one level up from bin/)
plugin_json="$(dirname "$script_dir")/.claude-plugin/plugin.json"
if [ -f "$plugin_json" ]; then
  version_line=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('version',''))" "$plugin_json" 2>/dev/null || true)
fi

ROWS=""; core_missing=0; checker_missing=0
add() { # status name category fix
  ROWS+="$1|$2|$3|$4"$'\n'
  if [ "$1" = MISSING ]; then
    [ "$3" = core ] && core_missing=$((core_missing + 1))
    [ "$3" = checker ] && checker_missing=$((checker_missing + 1))
  fi
}

detect() {
  local h="${SM_CHECKER_HARNESS:-pi}"
  h="$(printf '%s' "$h" | tr '\n\r|' '   ')"   # finding #9: no newline/pipe can inject/forge rows before JSON encoding
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
  # finding #1: build JSON with python so control chars (e.g. a newline in $SM_CHECKER_HARNESS) are escaped.
  # include version as first item if available
  version_json=""
  if [ -n "$version_line" ]; then
    version_json='{"name":"version","status":"OK","category":"meta","fix":""}'
  fi
  # build combined JSON from version (if available) and ROWS
  if [ -n "$version_json" ]; then
    echo "[$version_json,$(printf '%s' "$ROWS" | python3 -c '
import json,sys
out=[]
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    parts=(line.split("|",3)+["","","",""])[:4]
    st,name,cat,fix=parts
    out.append({"name":name,"status":st,"category":cat,"fix":fix})
print(json.dumps(out,separators=(",",":")))' | sed 's/^\[//;s/\]$//')]"
  else
    printf '%s' "$ROWS" | python3 -c 'import json,sys
out=[]
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    parts=(line.split("|",3)+["","","",""])[:4]
    st,name,cat,fix=parts
    out.append({"name":name,"status":st,"category":cat,"fix":fix})
print(json.dumps(out,separators=(",",":")))'
  fi
}

emit_table() {
  echo "secondmate doctor"
  echo "----------------------------------------------------------------------"
  if [ -n "$version_line" ]; then
    echo "  [ok] version $version_line"
  else
    echo "  [!!] version (unknown)"
  fi
  while IFS='|' read -r st name cat fix; do
    [ -z "$name" ] && continue
    local mark="[ok]"; [ "$st" = MISSING ] && mark="[!!]"
    printf '%-4s %-38s %-9s %s\n' "$mark" "$name" "$cat" "$fix"
  done <<< "$ROWS"
  echo "----------------------------------------------------------------------"
  echo "note: cross-model checking also needs a 2nd model family + credentials for your harness"
  echo "      (defaults: amazon-bedrock GPT-5.6 / DeepSeek-R1). Set SM_CHECKER_* / SM_REASON_* to yours."
  if [ "$core_missing" -gt 0 ]; then echo "STATUS: not ready. $core_missing core missing. Run: doctor.sh --heal"
  elif [ "$checker_missing" -gt 0 ]; then echo "STATUS: ready via in-session Claude fallback. No external checker harness found; install one (doctor.sh --heal) for a stronger cross-vendor check."
  else echo "STATUS: ready (core plus checker harness present)"; fi
}

heal() {
  local yes="$1"
  while IFS='|' read -r st name cat fix; do
    [ "$st" = MISSING ] || continue
    if [ -z "$fix" ]; then echo "SKIP  $name — no known auto-fix; provide its source (see README) and set the matching SM_* var"; continue; fi
    if [ "$yes" = 1 ]; then echo ">> healing $name: $fix"; bash -c "$fix" || echo "   (failed — do it manually: $fix)"
    else
      printf 'Fix %s via: %s\n  proceed? [y/N] ' "$name" "$fix"; read -r ans
      case "$ans" in y|Y) bash -c "$fix" || echo "   (failed — do it manually: $fix)";; *) echo "   skipped";; esac
    fi
  done <<< "$ROWS"
}

# --- selfcheck (no installs) ---
if [ "${1:-}" = "--selfcheck" ]; then
  # assert version line is present and non-empty
  [ -n "$version_line" ] || { echo "FAIL: version line is empty or missing"; exit 1; }
  out="$("$0" --json)" || { echo "FAIL: --json errored"; exit 1; }
  python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$out" || { echo "FAIL: --json not valid JSON"; exit 1; }
  "$0" >/dev/null 2>&1; rc=$?; [ "$rc" = 0 ] || [ "$rc" = 1 ] || { echo "FAIL: unexpected exit $rc"; exit 1; }
  # symlink regression test: invoke via a temp symlink and verify version still resolves
  tmpdir=$(mktemp -d)
  script_abs="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  ln -sf "$script_abs" "$tmpdir/doctor"
  symlink_out="$($tmpdir/doctor --json)"
  rm -rf "$tmpdir"
  # version must be present in JSON output
  echo "$symlink_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=[x for x in d if x["name"]=="version"]; assert v and v[0]["status"]=="OK", "version line missing or not OK in symlink run"' || { echo "FAIL: symlink regression test failed - version not resolved when invoked via symlink"; exit 1; }
  echo ok; exit 0
fi

detect
case "${1:-}" in
  --json) emit_json;;
  --heal) [ "${2:-}" = "--yes" ] && heal 1 || heal 0; echo; emit_table;;
  ""|--report) emit_table;;
  *) echo "usage: doctor.sh [--json|--heal [--yes]|--selfcheck]" >&2; exit 2;;
esac
[ "$core_missing" -eq 0 ]
