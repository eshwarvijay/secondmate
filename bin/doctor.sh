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

# --- symlink resolution function: resolves a script path through all symlink hops ---
# Usage: _resolve_symlink "$path" -> outputs absolute path or empty string on failure
# Each relative symlink target is resolved against the REAL directory of its parent symlink
# Cap at 40 hops (far more than any real chain needs) to prevent infinite loops on cycles
# Returns empty string if cycle detected or resolution fails
_resolve_symlink() {
  local _p="$1"
  local _hop=0
  local _max_hops=40
  
  # First resolve to absolute path
  case "$_p" in
    /*) ;;  # already absolute
    *) _p="$(pwd)/$_p" ;;
  esac

  while [ -L "$_p" ]; do
    _hop=$(( _hop + 1 ))
    [ "$_hop" -gt "$_max_hops" ] && return 1
    
    _target=$(readlink "$_p")
    _link_dir=$(cd "$(dirname "$_p")" 2>/dev/null && pwd) || return 1
    case "$_target" in
      /*) _p="$_target" ;;  # absolute target
      *) _p="$_link_dir/$_target" ;;  # relative target -> resolve against symlink's dir
    esac
  done

  # Return the resolved absolute path
  if [ -f "$_p" ]; then
    echo "$(cd "$(dirname "$_p")" && pwd)/$(basename "$_p")"
  fi
}

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
      # use fallback function when native tools unavailable
      _real_script=$(_resolve_symlink "${BASH_SOURCE[0]}")
    fi
  fi
fi
if [ -z "$_real_script" ]; then
  _real_script="${BASH_SOURCE[0]}"
fi
script_dir=""
if [ -d "$(dirname "$_real_script")" ]; then
  script_dir="$(cd "$(dirname "$_real_script")" && pwd)"
fi
version_line=""
# plugin.json lives in script_dir's parent (one level up from bin/)
plugin_json="$(dirname "$script_dir")/.claude-plugin/plugin.json"
if [ -f "$plugin_json" ]; then
  version_line=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('version',''))" "$plugin_json" 2>/dev/null || true)
fi

# secondmate plugin staleness detection constants
_marketplace_checkout="$HOME/.claude/plugins/marketplaces/secondmate"
_installed_plugins_json="$HOME/.claude/plugins/installed_plugins.json"
_doctor_lock_dir="$HOME/.secondmate-doctor-lock"
_doctor_lock_file="$_doctor_lock_dir/secondmate-heal.lock"

# get current running script's git commit SHA (from its own marketplace checkout)
# This is the version that's currently loaded in this session
_running_script_sha=""
if [ -d "$_marketplace_checkout" ] && git -C "$_marketplace_checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _running_script_sha=$(git -C "$_marketplace_checkout" rev-parse HEAD 2>/dev/null || true)
fi

ROWS=""; core_missing=0; checker_missing=0
add() { # status name category fix
  ROWS+="$1|$2|$3|$4"$'\n'
  if [ "$1" = MISSING ]; then
    [ "$3" = core ] && core_missing=$((core_missing + 1))
    [ "$3" = checker ] && checker_missing=$((checker_missing + 1))
  fi
}

# Helper to detect secondmate plugin staleness
# Usage: _detect_secondmate_status, sets _sm_status and _sm_details global variables
_detect_secondmate_status() {
  _sm_status="unknown"
  _sm_details=""
  
  # Check if marketplace checkout exists
  if [ ! -d "$_marketplace_checkout" ]; then
    _sm_status="missing"
    _sm_details="marketplace checkout not found"
    return
  fi
  
  # Get marketplace HEAD SHA
  local marketplace_sha=""
  marketplace_sha=$(git -C "$_marketplace_checkout" rev-parse HEAD 2>/dev/null) || {
    _sm_status="unknown"
    _sm_details="cannot read marketplace HEAD"
    return
  }
  [ -z "$marketplace_sha" ] && { _sm_status="unknown"; _sm_details="marketplace HEAD is empty"; return; }
  
  # Check if installed_plugins.json exists and has secondmate entry
  if [ ! -f "$_installed_plugins_json" ]; then
    _sm_status="unknown"
    _sm_details="installed_plugins.json not found"
    return
  fi
  
  # Extract the installed secondmate SHA from installed_plugins.json
  local installed_sha=""
  installed_sha=$(python3 -c "
import json,sys
try:
    data=json.load(open(sys.argv[1]))
    plugins = data.get('plugins', {})
    if isinstance(plugins, dict):
        # Structure: plugins is a dict with keys like 'name@scope'
        for key, entries in plugins.items():
            if isinstance(entries, list):
                for entry in entries:
                    if isinstance(entry, dict):
                        if key.startswith('secondmate@'):
                            print(entry.get('gitCommitSha', ''))
                            sys.exit(0)
except Exception as e:
    import sys
    print(f'Error: {e}', file=sys.stderr)
    pass
print('', end='')
sys.exit(1)
" "$_installed_plugins_json" 2>/dev/null) || installed_sha=""
  [ -z "$installed_sha" ] && { _sm_status="unknown"; _sm_details="secondmate not found in installed_plugins.json"; return; }
  
  # Get marketplace plugin.json version
  local marketplace_version=""
  if [ -f "$_marketplace_checkout/.claude-plugin/plugin.json" ]; then
    marketplace_version=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('version',''))" "$_marketplace_checkout/.claude-plugin/plugin.json" 2>/dev/null || true)
  fi
  [ -z "$marketplace_version" ] && { _sm_status="unknown"; _sm_details="cannot read marketplace version"; return; }
  
  # Get running script's version
  local running_version=""
  if [ -f "$plugin_json" ]; then
    running_version=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('version',''))" "$plugin_json" 2>/dev/null || true)
  fi
  
  # Compare SHAs
  if [ "$marketplace_sha" = "$installed_sha" ]; then
    _sm_status="ok"
    _sm_details="installed and marketplace SHAs match"
  else
    # SHA differs — check if version also changed (silent drift)
    if [ "$marketplace_version" = "$running_version" ]; then
      # Version didn't change but SHA differs — silent drift
      _sm_status="silent_drift"
      _sm_details="new commits but version unchanged (claude plugin update won't act)"
    else
      # Both SHA and version changed — stale and can be healed
      _sm_status="stale"
      _sm_details="marketplace ahead of installed (sha $installed_sha -> $marketplace_sha)"
    fi
  fi
  
  # Check for reload pending: currently running version differs from latest in installed_plugins.json
  if [ "$running_version" != "$marketplace_version" ]; then
    # If version differs, that means /reload-plugins hasn't been run yet
    _sm_status="reload_pending"
    _sm_details="heal completed but /reload-plugins not yet run"
  fi
}

# Add secondmate staleness row
_detect_secondmate_staleness() {
  _detect_secondmate_status
  
  local fix_cmd=""
  case "$_sm_status" in
    stale)
      fix_cmd="doctor.sh --heal (pulls and re-installs secondmate plugin)"
      add STALE "secondmate plugin (stale)" companion "$fix_cmd"
      ;;
    silent_drift)
      fix_cmd="doctor.sh --heal (pull succeeds but update is blocked until version bump)"
      add STALE "secondmate plugin (silent drift)" companion "$fix_cmd"
      ;;
    reload_pending)
      fix_cmd="claude /reload-plugins (reload into running session)"
      add STALE "secondmate plugin (reload pending)" companion "$fix_cmd"
      ;;
    missing)
      fix_cmd="claude plugin marketplace add eshwarvijay/secondmate"
      add MISSING "secondmate plugin (marketplace)" companion "$fix_cmd"
      ;;
    ok)
      add OK "secondmate plugin" companion ""
      ;;
    *)
      add UNKNOWN "secondmate plugin" companion ""
      ;;
  esac
}

# Lock mechanism for heal operations (mkdir-based atomic lock)
_acquire_heal_lock() {
  local max_wait=30  # 30 seconds
  local wait_interval=1
  local elapsed=0
  
  mkdir -p "$_doctor_lock_dir"
  
  while [ ! -d "$_doctor_lock_file" ]; do
    if mkdir "$_doctor_lock_file" 2>/dev/null; then
      # Lock acquired, write our PID
      echo "$$" > "$_doctor_lock_file/.pid"
      echo "$(date +%s)" > "$_doctor_lock_file/.timestamp"
      return 0
    fi
    
    # Check if lock is stale (older than max_wait)
    if [ -f "$_doctor_lock_file/.timestamp" ]; then
      local lock_age
      lock_age=$(( $(date +%s) - $(cat "$_doctor_lock_file/.timestamp" 2>/dev/null || echo $max_wait) ))
      if [ "$lock_age" -gt "$max_wait" ]; then
        # Stale lock, try to steal it
        rm -rf "$_doctor_lock_file" 2>/dev/null
        continue
      fi
    fi
    
    sleep "$wait_interval"
    elapsed=$((elapsed + wait_interval))
    if [ "$elapsed" -ge "$max_wait" ]; then
      echo "heal cancelled: could not acquire lock after ${max_wait}s" >&2
      return 1
    fi
  done
  
  # If we got here, the lock directory already exists (someone else got it)
  echo "heal cancelled: another heal is already in progress" >&2
  return 1
}

_release_heal_lock() {
  rm -rf "$_doctor_lock_file" 2>/dev/null
}

# Heal secondmate plugin
_heal_secondmate() {
  local yes="$1"
  local abort_reason=""
  
  # Check if claude CLI exists
  if ! have claude; then
    echo "[FAIL] claude CLI not found on PATH"
    echo "       please ensure claude is installed and on your PATH"
    return 1
  fi
  
  # Check if marketplace checkout exists
  if [ ! -d "$_marketplace_checkout" ]; then
    echo "[FAIL] secondmate marketplace checkout not found at $_marketplace_checkout"
    echo "       run: claude plugin marketplace add eshwarvijay/secondmate"
    return 1
  fi
  
  # Check for uncommitted changes (dirty tree)
  local dirty_files
  dirty_files=$(git -C "$_marketplace_checkout" status --porcelain 2>/dev/null)
  if [ -n "$dirty_files" ]; then
    echo "[FAIL] marketplace checkout has uncommitted changes:"
    git -C "$_marketplace_checkout" status --porcelain | sed 's/^/       /'
    echo ""
    echo "       cannot heal with dirty working tree"
    echo "       please commit, stash, or discard changes first"
    return 1
  fi
  
  # Check if on detached HEAD or non-fast-forward capable
  local current_branch
  current_branch=$(git -C "$_marketplace_checkout" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$current_branch" = "HEAD" ]; then
    echo "[FAIL] marketplace checkout is on detached HEAD"
    echo "       heal requires a named branch for safe fast-forward pulls"
    return 1
  fi
  
  # Try to fetch + fast-forward only (no merge, no rebase, no force)
  echo "[INFO] pulling marketplace checkout..."
  if ! git -C "$_marketplace_checkout" fetch origin 2>/dev/null; then
    echo "[FAIL] git fetch failed"
    return 1
  fi
  
  # Get remote branch ref
  local remote_ref="origin/$current_branch"
  if ! git -C "$_marketplace_checkout" rev-parse --verify "$remote_ref" >/dev/null 2>&1; then
    # Try with refs/heads/ prefix
    remote_ref="refs/heads/$current_branch"
    if ! git -C "$_marketplace_checkout" rev-parse --verify "$remote_ref" >/dev/null 2>&1; then
      echo "[FAIL] cannot determine remote branch for fast-forward"
      return 1
    fi
  fi
  
  # Check if this is a fast-forward (local is ancestor of remote)
  local local_sha remote_sha merge_base
  local_sha=$(git -C "$_marketplace_checkout" rev-parse HEAD 2>/dev/null) || {
    echo "[FAIL] cannot read local SHA"
    return 1
  }
  remote_sha=$(git -C "$_marketplace_checkout" rev-parse "$remote_ref" 2>/dev/null) || {
    echo "[FAIL] cannot read remote SHA"
    return 1
  }
  
  merge_base=$(git -C "$_marketplace_checkout" merge-base "$local_sha" "$remote_sha" 2>/dev/null) || {
    echo "[FAIL] cannot compute merge base"
    return 1
  }
  
  if [ "$merge_base" != "$local_sha" ]; then
    echo "[FAIL] pull would not be a fast-forward (local has diverged from remote)"
    echo "       local commit $local_sha is not an ancestor of $remote_ref"
    echo "       heal requires clean fast-forward; aborting to preserve local state"
    return 1
  fi
  
  # Perform fast-forward only pull
  if ! git -C "$_marketplace_checkout" pull --ff-only 2>/dev/null; then
    echo "[FAIL] git pull --ff-only failed"
    return 1
  fi
  
  echo "[OK] marketplace checkout updated"
  
  # Check if claude plugin update would actually do something
  local current_version new_version
  current_version=$(python3 -c "import json,sys; d=json.load(open('$plugin_json')); print(d.get('version',''))" 2>/dev/null || true)
  new_version=$(python3 -c "import json,sys; d=json.load(open('$_marketplace_checkout/.claude-plugin/plugin.json')); print(d.get('version',''))" 2>/dev/null || true)
  
  if [ "$current_version" = "$new_version" ]; then
    echo "[SKIP] claude plugin update is not applicable (version unchanged)"
    echo "       new commits exist but version string was not bumped"
    echo "       run 'claude plugin update secondmate@secondmate' manually to force"
    return 0
  fi
  
  # Run the actual plugin update
  if [ "$yes" = 1 ]; then
    echo "[INFO] running claude plugin update secondmate@secondmate -y"
    if ! claude plugin update secondmate@secondmate -y 2>&1; then
      echo "[FAIL] claude plugin update failed"
      echo "       marketplace checkout was updated but plugin was not reinstalled"
      echo "       run 'claude plugin update secondmate@secondmate' manually to complete"
      return 1
    fi
  else
    printf '[INFO] claude plugin update secondmate@secondmate will run\n  proceed? [y/N] '
    read -r ans
    case "$ans" in
      y|Y)
        echo "[INFO] running claude plugin update secondmate@secondmate"
        if ! claude plugin update secondmate@secondmate 2>&1; then
          echo "[FAIL] claude plugin update failed"
          echo "       marketplace checkout was updated but plugin was not reinstalled"
          echo "       run 'claude plugin update secondmate@secondmate' manually to complete"
          return 1
        fi
        ;;
      *)
        echo "[ABORTED] claude plugin update skipped"
        return 0
        ;;
    esac
  fi
  
  # Verify the heal by re-reading installed_plugins.json fresh from disk
  echo "[VERIFY] re-reading installed_plugins.json to confirm SHA advance..."
  local after_sha
  after_sha=$(python3 -c "
import json,sys
try:
    data=json.load(open(sys.argv[1]))
    plugins = data.get('plugins', {})
    if isinstance(plugins, dict):
        for key, entries in plugins.items():
            if isinstance(entries, list):
                for entry in entries:
                    if isinstance(entry, dict):
                        if key.startswith('secondmate@'):
                            print(entry.get('gitCommitSha', ''))
                            sys.exit(0)
except Exception as e:
    import sys
    print(f'Error: {e}', file=sys.stderr)
    pass
print('', end='')
sys.exit(1)
" "$_installed_plugins_json" 2>/dev/null)
  
  if [ -z "$after_sha" ]; then
    echo "[WARN] cannot verify heal - secondmate not found in installed_plugins.json"
    echo "       but plugin update may have succeeded"
    return 0
  fi
  
  local after_version
  after_version=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('version',''))" "$_installed_plugins_json" 2>/dev/null || true)
  
  if [ "$after_sha" != "$local_sha" ]; then
    echo "[OK] SHA advanced: $local_sha -> $after_sha (version: $current_version -> $after_version)"
  else
    echo "[WARN] SHA unchanged after heal - plugin may not have reinstalled properly"
  fi
  
  # Print the reload reminder
  echo ""
  echo "============================================================"
  echo "  IMPORTANT: /reload-plugins is still required to load"
  echo "  the healed plugin into any currently-running session."
  echo "  This is a genuine, permanent limitation (a bash script"
  echo "  cannot trigger a Claude Code slash command)."
  echo "============================================================"
  
  return 0
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
  # SECONDMATE PLUGIN STALENESS — check if the running copy is stale compared to marketplace checkout
  _detect_secondmate_staleness
}

emit_json() {
  # finding #1: build JSON with python so control chars (e.g. a newline in $SM_CHECKER_HARNESS) are escaped.
  printf '%s' "$ROWS" | python3 -c 'import json,sys
out=[]
for line in sys.stdin.read().splitlines():
    if not line.strip(): continue
    parts=(line.split("|",3)+["","","",""])[:4]
    st,name,cat,fix=parts
    out.append({"name":name,"status":st,"category":cat,"fix":fix})
print(json.dumps(out,separators=(",",":")))'
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
  
  # Handle secondmate plugin staleness first
  _detect_secondmate_status
  if [ "$_sm_status" = "stale" ] || [ "$_sm_status" = "silent_drift" ]; then
    echo "=== SECONDMATE PLUGIN HEAL ==="
    _acquire_heal_lock || {
      echo "Heal not performed."
      return 1
    }
    trap '_release_heal_lock' EXIT
    
    _heal_secondmate "$yes"
    heal_result=$?
    _release_heal_lock
    trap - EXIT
    
    echo
  fi
  
  # Then heal other missing items
  while IFS='|' read -r st name cat fix; do
    [ "$st" = MISSING ] || continue
    # Skip secondmate here since we already handled it above
    [ "$name" = "secondmate plugin (marketplace)" ] && continue
    [ "$name" = "secondmate plugin (stale)" ] && continue
    [ "$name" = "secondmate plugin (silent drift)" ] && continue
    [ "$name" = "secondmate plugin (reload pending)" ] && continue
    [ -z "$fix" ] && { echo "SKIP  $name — no known auto-fix; provide its source (see README) and set the matching SM_* var"; continue; }
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
  # symlink regression test: invoke via temp symlink and verify version still resolves
  tmpdir=$(mktemp -d)
  script_abs="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  ln -sf "$script_abs" "$tmpdir/doctor"
  symlink_table="$($tmpdir/doctor)"
  rm -rf "$tmpdir"
  # verify version line is present in table output
  echo "$symlink_table" | grep -q "^  \[ok\] version " || { echo "FAIL: symlink regression test failed - version not resolved when invoked via symlink"; exit 1; }
  
  # two-hop relative symlink chain test (exercises the fallback loop directly via _resolve_symlink)
  tmpdir2=$(mktemp -d)
  mkdir -p "$tmpdir2/a/sub" "$tmpdir2/b" "$tmpdir2/r/bin"
  touch "$tmpdir2/r/bin/doctor.sh"  # stand-in target file
  # create two-hop chain: a/sub/doctor -> ../../b/hop -> ../r/bin/doctor.sh
  ln -sf "../../b/hop" "$tmpdir2/a/sub/doctor"
  ln -sf "../r/bin/doctor.sh" "$tmpdir2/b/hop"
  # capture expected resolved path BEFORE rm -rf
  expected="$tmpdir2/r/bin/doctor.sh"
  resolved=$(_resolve_symlink "$tmpdir2/a/sub/doctor")
  rm -rf "$tmpdir2"
  [ "$resolved" = "$expected" ] || { echo "FAIL: two-hop symlink regression test failed - got '$resolved', expected '$expected'"; exit 1; }
  
  # cycle regression test -- calls the REAL _resolve_symlink function directly, no subshell/timeout dependency
  _cycle_test_dir=$(mktemp -d)
  ln -sf "$_cycle_test_dir/a" "$_cycle_test_dir/b"
  ln -sf "$_cycle_test_dir/b" "$_cycle_test_dir/a"
  _cycle_start=$(date +%s)
  _cycle_result=$(_resolve_symlink "$_cycle_test_dir/a")
  _cycle_rc=$?
  _cycle_elapsed=$(( $(date +%s) - _cycle_start ))
  rm -rf "$_cycle_test_dir"
  { [ -z "$_cycle_result" ] && [ "$_cycle_elapsed" -lt 5 ]; } || { echo "FAIL: cycle test -- result='$_cycle_result' rc=$_cycle_rc elapsed=${_cycle_elapsed}s (expected empty result within 5s)"; exit 1; }
  
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
