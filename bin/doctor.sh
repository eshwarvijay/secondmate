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
# SM_* env vars allow overrides (for testing). Default to real paths if unset.
_marketplace_checkout="${SM_SECONDMATE_MARKETPLACE_DIR:-$HOME/.claude/plugins/marketplaces/secondmate}"
_installed_plugins_json="${SM_INSTALLED_PLUGINS_JSON:-$HOME/.claude/plugins/installed_plugins.json}"
_doctor_lock_dir="${SM_DOCTOR_LOCK_DIR:-$HOME/.secondmate-doctor-lock}"
_doctor_lock_file="$_doctor_lock_dir/secondmate-heal.lock"

# get current running script's git commit SHA (from its own marketplace checkout)
# This is the version that's currently loaded in this session
_running_script_sha=""
if [ -d "$_marketplace_checkout" ] && git -C "$_marketplace_checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _running_script_sha=$(git -C "$_marketplace_checkout" rev-parse HEAD 2>/dev/null || true)
fi

# --- state initialization helper ---
_reset_detect_state() {
  ROWS=""; core_missing=0; checker_missing=0; stale_count=0; reload_pending_count=0; unknown_count=0; missing_marketplace_count=0
}

# --- Bedrock model override helpers ---
# Extract model-id from PLANNERS array by label (pipe-delimited: label|dimension|model-id|thinking-level)
# Usage: _bedrock_get_model_id "kimi-k3" -> outputs global.moonshotai.kimi-k3 or empty
# Bug 3 fix: plan-committee.sh path is now overridable via SM_PLANCOMMITTEE_PATH env var
# for test fixtures (matching the existing convention: SM_SECONDMATE_MARKETPLACE_DIR, etc.)
# Round 7 fix: use the GLOBAL $script_dir (already symlink-resolved) instead of re-declaring
# a NEW local script_dir that breaks symlink invocation
_bedrock_get_model_id() {
  local label="$1"
  local source_file="${SM_PLANCOMMITTEE_PATH:-$script_dir/plan-committee.sh}"
  
  if [ ! -f "$source_file" ]; then
    return 1
  fi
  
  # Delegate parsing to Python via environment variables (avoids heredoc quote escaping hell)
  PLANNERS_LABEL="$label" PLANNERS_SOURCE="$source_file" python3 << 'PYEOF' || return $?
import sys
import os
import re

label = os.environ.get('PLANNERS_LABEL', '')
source_file = os.environ.get('PLANNERS_SOURCE', '')

if not label or not source_file:
    sys.exit(1)

try:
    with open(source_file, 'r') as f:
        content = f.read()
except Exception:
    sys.exit(1)

# Find PLANNERS array definition
match = re.search(r'PLANNERS=\(([^)]+)\)', content, re.DOTALL)
if not match:
    sys.exit(1)

array_content = match.group(1)

# Extract entries matching "label|dimension|model-id|thinking-level"
entries = re.findall(r'"([^"]+)"', array_content)

for entry in entries:
    parts = entry.split('|')
    if len(parts) >= 3 and parts[0] == label:
        print(parts[2])  # Print the model-id (3rd field)
        sys.exit(0)

# Label not found in PLANNERS - UNKNOWN territory
sys.exit(1)
PYEOF
  return $?
}

# Validate model override value is valid (present, numeric, <= threshold)
# Usage: _bedrock_validate_kimi_k3 <json_path> <model_id> -> 0 if valid
# Fix: pass values via env vars, not string interpolation, to avoid quote-breaking bugs
_bedrock_validate_kimi_k3() {
  local json_path="$1"
  local model_id="$2"
  local threshold=128000  # Bedrock's own real enforced ceiling for Kimi K3, confirmed via live Validation error response on 2026-09-23
  
  if [ ! -f "$json_path" ]; then
    return 1
  fi
  
  # Use env vars instead of string interpolation to avoid quote-breaking bugs
  BEDROCK_JSON_PATH="$json_path" BEDROCK_MODEL_ID="$model_id" BEDROCK_THRESHOLD="$threshold" python3 << 'PYEOF' || return $?
import json, sys, os

json_path = os.environ.get('BEDROCK_JSON_PATH', '')
model_id = os.environ.get('BEDROCK_MODEL_ID', '')
threshold = int(os.environ.get('BEDROCK_THRESHOLD', '0'))

try:
    with open(json_path, 'r') as f:
        data = json.load(f)
except (json.JSONDecodeError, Exception):
    sys.exit(1)

providers = data.get('providers', {})
if not isinstance(providers, dict):
    sys.exit(1)

bedrock = providers.get('amazon-bedrock', {})
if not isinstance(bedrock, dict):
    sys.exit(1)

model_overrides = bedrock.get('modelOverrides', {})
if not isinstance(model_overrides, dict):
    sys.exit(1)

override = model_overrides.get(model_id, {})
if not isinstance(override, dict):
    sys.exit(1)

max_tokens = override.get('maxTokens')
# Consolidated robust numeric validation: positive whole number <= threshold, reject NaN/Infinity, reject bool
import math as _m
ok = (isinstance(max_tokens, (int, float))
      and not isinstance(max_tokens, bool)
      and _m.isfinite(max_tokens)
      and max_tokens == int(max_tokens)
      and max_tokens > 0
      and max_tokens <= threshold)
if not ok:
    sys.exit(1)

sys.exit(0)
PYEOF
  return $?
}

# Validate deepseek-r1 model entry (must exist with maxTokens <= 32768)
# Usage: _bedrock_validate_deepseek_r1 <json_path> <model_id> -> 0 if valid  
# Fix: pass values via env vars, not string interpolation
_bedrock_validate_deepseek_r1() {
  local json_path="$1"
  local model_id="$2"
  local threshold=32768  # Bedrock's own real enforced ceiling for DeepSeek R1, confirmed via live Validation error response on 2026-09-23
  
  if [ ! -f "$json_path" ]; then
    return 1
  fi
  
  BEDROCK_JSON_PATH="$json_path" BEDROCK_MODEL_ID="$model_id" BEDROCK_THRESHOLD="$threshold" python3 << 'PYEOF' || return $?
import json, sys, os

json_path = os.environ.get('BEDROCK_JSON_PATH', '')
model_id = os.environ.get('BEDROCK_MODEL_ID', '')
threshold = int(os.environ.get('BEDROCK_THRESHOLD', '0'))

try:
    with open(json_path, 'r') as f:
        data = json.load(f)
except (json.JSONDecodeError, Exception):
    sys.exit(1)

providers = data.get('providers', {})
if not isinstance(providers, dict):
    sys.exit(1)

bedrock = providers.get('amazon-bedrock', {})
if not isinstance(bedrock, dict):
    sys.exit(1)

models = bedrock.get('models', [])
if not isinstance(models, list):
    sys.exit(1)

for entry in models:
    if not isinstance(entry, dict):
        continue
    if entry.get('id') == model_id:
        max_tokens = entry.get('maxTokens')
        # Consolidated robust numeric validation (same logic as kimi-k3)
        import math as _m
        ok = (isinstance(max_tokens, (int, float))
              and not isinstance(max_tokens, bool)
              and _m.isfinite(max_tokens)
              and max_tokens == int(max_tokens)
              and max_tokens > 0
              and max_tokens <= threshold)
        if ok:
            sys.exit(0)
        sys.exit(1)

# Entry not found
sys.exit(1)
PYEOF
  return $?
}

# Build safe JSON merge for kimi-k3 with atomic write
# Usage: _bedrock_fix_kimi_k3 <json_path> <model_id> -> 0 on success
# Fix: read the EXISTING per-model override object first (default to {} if absent or not a dict),
# set only the maxTokens key on it, then assign that same object back — preserving any other keys already there
# (Bug 1 fix: previous version REPLACED the whole object instead of merging into it)
_bedrock_fix_kimi_k3() {
  local json_path="$1"
  local model_id="$2"
  local safe_target=120000  # Safe concrete target below Bedrock's 128000 ceiling
  local temp_file="${json_path}.tmp.$$"
  
  # Pass all values via env vars to avoid quote-breaking bugs
  BEDROCK_JSON_PATH="$json_path" BEDROCK_MODEL_ID="$model_id" BEDROCK_SAFE_TARGET="$safe_target" BEDROCK_TEMP_FILE="$temp_file" python3 << 'PYEOF' || return $?
import json, sys, os

json_path = os.environ.get('BEDROCK_JSON_PATH', '')
model_id = os.environ.get('BEDROCK_MODEL_ID', '')
safe_target = int(os.environ.get('BEDROCK_SAFE_TARGET', '0'))
temp_file = os.environ.get('BEDROCK_TEMP_FILE', '')

# Read existing file or create empty structure
if os.path.exists(json_path):
    try:
        with open(json_path, 'r') as f:
            data = json.load(f)
    except json.JSONDecodeError:
        print('fix failed: models.json is malformed JSON', file=sys.stderr)
        sys.exit(1)
else:
    data = {}

# Ensure providers exists
providers = data.get('providers')
if not isinstance(providers, dict):
    data['providers'] = {}
    providers = data['providers']

# Ensure amazon-bedrock exists under providers
bedrock = providers.get('amazon-bedrock')
if not isinstance(bedrock, dict):
    providers['amazon-bedrock'] = {}
    bedrock = providers['amazon-bedrock']

# Ensure modelOverrides exists
model_overrides = bedrock.get('modelOverrides')
if not isinstance(model_overrides, dict):
    bedrock['modelOverrides'] = {}
    model_overrides = bedrock['modelOverrides']

# Bug 1 fix: read existing override object (default to {}), set only maxTokens, preserve all other keys
existing_override = model_overrides.get(model_id, {})
if not isinstance(existing_override, dict):
    existing_override = {}
existing_override['maxTokens'] = safe_target
model_overrides[model_id] = existing_override

# Validate the JSON is still valid
json.dumps(data)

# Write atomically: temp file, validate, then mv
try:
    # Finding 1 fix: create parent directory if it doesn't exist
    temp_dir = os.path.dirname(temp_file)
    if temp_dir:
        os.makedirs(temp_dir, exist_ok=True)
    
    with open(temp_file, 'w') as f:
        json.dump(data, f, indent=2)
    
    # Validate temp file is valid JSON
    with open(temp_file, 'r') as f:
        json.load(f)
    
    os.rename(temp_file, json_path)
    sys.exit(0)
except Exception as e:
    # Clean up temp file if it exists
    if os.path.exists(temp_file):
        try:
            os.remove(temp_file)
        except:
            pass
    print(f'fix failed: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
  return $?
}

# Build safe JSON merge for deepseek-r1 with atomic write
# Usage: _bedrock_fix_deepseek_r1 <json_path> <model_id> -> 0 on success
# Fix: pass values via env vars, not string interpolation
_bedrock_fix_deepseek_r1() {
  local json_path="$1"
  local model_id="$2"
  local safe_target=30000  # Safe concrete target below Bedrock's 32768 ceiling
  local temp_file="${json_path}.tmp.$$"
  
  # Pass all values via env vars to avoid quote-breaking bugs
  BEDROCK_JSON_PATH="$json_path" BEDROCK_MODEL_ID="$model_id" BEDROCK_SAFE_TARGET="$safe_target" BEDROCK_TEMP_FILE="$temp_file" python3 << 'PYEOF' || return $?
import json, sys, os

json_path = os.environ.get('BEDROCK_JSON_PATH', '')
model_id = os.environ.get('BEDROCK_MODEL_ID', '')
safe_target = int(os.environ.get('BEDROCK_SAFE_TARGET', '0'))
temp_file = os.environ.get('BEDROCK_TEMP_FILE', '')

# Read existing file or create empty structure
if os.path.exists(json_path):
    try:
        with open(json_path, 'r') as f:
            data = json.load(f)
    except json.JSONDecodeError:
        print('fix failed: models.json is malformed JSON', file=sys.stderr)
        sys.exit(1)
else:
    data = {}

# Ensure providers exists
providers = data.get('providers')
if not isinstance(providers, dict):
    data['providers'] = {}
    providers = data['providers']

# Ensure amazon-bedrock exists under providers
bedrock = providers.get('amazon-bedrock')
if not isinstance(bedrock, dict):
    providers['amazon-bedrock'] = {}
    bedrock = providers['amazon-bedrock']

# Ensure models list exists
models = bedrock.get('models')
if not isinstance(models, list):
    bedrock['models'] = []
    models = bedrock['models']

# Fix Finding: MERGE canonical fields into existing entry (don't replace the whole object)
# Preserve any custom fields a user might have added
new_entry = {
    'id': model_id,
    'api': 'bedrock-converse-stream',
    'baseUrl': 'https://bedrock-runtime.us-east-1.amazonaws.com',
    'name': 'DeepSeek R1',
    'reasoning': True,
    'contextWindow': 128000,
    'maxTokens': safe_target
}

# Look for existing entry with the same id
found = False
for entry in models:
    if isinstance(entry, dict) and entry.get('id') == model_id:
        # Merge canonical fields into existing entry, preserving custom keys
        entry.update(new_entry)
        found = True
        break

# If no existing entry found, append the canonical new entry
if not found:
    models.append(dict(new_entry))  # dict() to copy

# Validate the JSON is still valid
json.dumps(data)

# Write atomically: temp file, validate, then mv
try:
    # Finding 1 fix: create parent directory if it doesn't exist
    temp_dir = os.path.dirname(temp_file)
    if temp_dir:
        os.makedirs(temp_dir, exist_ok=True)
    
    with open(temp_file, 'w') as f:
        json.dump(data, f, indent=2)
    
    # Validate temp file is valid JSON
    with open(temp_file, 'r') as f:
        json.load(f)
    
    os.rename(temp_file, json_path)
    sys.exit(0)
except Exception as e:
    # Clean up temp file if it exists
    if os.path.exists(temp_file):
        try:
            os.remove(temp_file)
        except:
            pass
    print(f'fix failed: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
  return $?
}

# initialize top-level state
_reset_detect_state
add() { # status name category fix
  ROWS+="$1|$2|$3|$4"$'\n'
  if [ "$1" = MISSING ]; then
    [ "$3" = core ] && core_missing=$((core_missing + 1))
    [ "$3" = checker ] && checker_missing=$((checker_missing + 1))
    # secondmate's missing marketplace checkout is a hard-abort condition (premises check)
    [ "$2" = "secondmate plugin (marketplace)" ] && missing_marketplace_count=$((missing_marketplace_count + 1))
  elif [ "$1" = STALE ]; then
    stale_count=$((stale_count + 1))
  elif [ "$1" = RELOAD_PENDING ]; then
    reload_pending_count=$((reload_pending_count + 1))
  elif [ "$1" = UNKNOWN ]; then
    unknown_count=$((unknown_count + 1))
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
  
  # Extract the installed secondmate SHA and version from installed_plugins.json
  local installed_sha=""
  local installed_version=""
  read -r installed_sha installed_version < <(python3 -c "
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
                            sha = entry.get('gitCommitSha', '')
                            ver = entry.get('version', '')
                            print(sha, ver)
                            sys.exit(0)
except Exception as e:
    import sys
    print(f'Error: {e}', file=sys.stderr)
    pass
print('', end='')
sys.exit(1)
" "$_installed_plugins_json" 2>/dev/null) || { installed_sha=""; installed_version=""; }
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
  
  # Compare SHAs - mutually exclusive states
  if [ "$marketplace_sha" = "$installed_sha" ]; then
    # SHA matches - check if version matches (ok) or version differs (reload_pending)
    if [ "$running_version" = "$installed_version" ]; then
      _sm_status="ok"
      _sm_details="installed and marketplace SHAs match, version in sync"
    else
      # Installed SHA matches marketplace SHA, but version differs
      # This means the plugin was already healed (claude plugin update ran),
      # but /reload-plugins hasn't been run yet to pick up the new version
      _sm_status="reload_pending"
      _sm_details="heal completed but /reload-plugins not yet run"
    fi
  else
    # SHA differs — installed is behind marketplace
    # Compare installed_version against marketplace_version (not running_version)
    # to determine if a real version bump occurred:
    # - if installed_version != marketplace_version: stale (healable bump happened)
    # - if installed_version == marketplace_version: silent_drift (no bump, healing won't help)
    if [ "$installed_version" = "$marketplace_version" ]; then
      # Version didn't change since installation but SHA differs — silent drift
      _sm_status="silent_drift"
      _sm_details="new commits but version unchanged (claude plugin update won't act)"
    else
      # Version changed since installation — stale and can be healed
      _sm_status="stale"
      _sm_details="marketplace ahead of installed (sha $installed_sha -> $marketplace_sha)"
    fi
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
      add RELOAD_PENDING "secondmate plugin (reload pending)" companion "$fix_cmd"
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
# Returns 0 if lock acquired or stolen, 1 if in-use or timeout
# Bug 5 fix: Use helper function to re-verify stale lock between reads and rm -rf
_acquire_heal_lock() {
  local max_wait=30  # 30 seconds
  local wait_interval=1
  local elapsed=0
  
  mkdir -p "$_doctor_lock_dir"
  
  while true; do  # Loop forever until we acquire lock or timeout
    # First, check if lock directory exists
    if [ ! -d "$_doctor_lock_file" ]; then
      # Lock doesn't exist, try to acquire it
      if mkdir "$_doctor_lock_file" 2>/dev/null; then
        # Lock acquired, write our PID
        echo "$$" > "$_doctor_lock_file/.pid"
        echo "$(date +%s)" > "$_doctor_lock_file/.timestamp"
        return 0
      fi
      # mkdir failed - someone else got it first (race condition)
    else
      # Lock directory exists, check if it's stale
      if [ -f "$_doctor_lock_file/.timestamp" ]; then
        # Read lock metadata once
        local lock_timestamp lock_pid lock_age
        lock_timestamp=$(cat "$_doctor_lock_file/.timestamp" 2>/dev/null || echo 0)
        lock_pid=$(cat "$_doctor_lock_file/.pid" 2>/dev/null || echo 0)
        lock_age=$(( $(date +%s) - lock_timestamp ))
        
        # Bug 5 fix: Extract stale check into helper for deterministic testing
        # and TOCTOU-safe re-verification (pass original timestamp and pid)
        # Bug 6 fix: _is_lock_still_stale now also checks if PID is alive before stealing
        # Bug 11 fix: Use atomic rename to claim the lock before touching it
        if _is_lock_still_stale "$lock_timestamp" "$max_wait" "$lock_pid"; then
          # Stale lock, try to atomically steal it with mv (atomic within same filesystem)
          local stolen_lock="${_doctor_lock_file}.stealing.$$"
          if mv "$_doctor_lock_file" "$stolen_lock" 2>/dev/null; then
            # We successfully moved the lock - now verify it's still the same stale lock
            # Read the MOVED copy's metadata to verify it matches what we originally read
            local current_ts current_pid
            current_ts=$(cat "$stolen_lock/.timestamp" 2>/dev/null || echo "")
            current_pid=$(cat "$stolen_lock/.pid" 2>/dev/null || echo "")
            
            # Re-verify: did anything change between our first read and this mv success?
            # If the values don't match our original read, another process replaced it
            if [ "$current_ts" != "$lock_timestamp" ] || [ "$current_pid" != "$lock_pid" ]; then
              # Someone else already stole/replaced the lock - back off and retry
              rm -rf "$stolen_lock" 2>/dev/null
              continue  # Loop back and re-evaluate from scratch
            fi
            
            # It's genuinely our stale lock - remove it and create fresh lock
            rm -rf "$stolen_lock" 2>/dev/null
            continue  # Retry (lock is gone now)
          else
            # mv failed - someone else already claimed it (or it's gone)
            # Back off and retry from scratch (don't create new lock yet)
            continue
          fi
        fi
      fi
      # Lock exists and is not stale, OR we couldn't read timestamp
      # This means another heal is actively running (not stale)
      echo "heal cancelled: another heal is already in progress" >&2
      return 1
    fi
    
    # We didn't acquire the lock this iteration, wait and retry
    # Only wait if we're in the "race condition" case (mkdir failed, lock gained in between)
    # For lock-exists-not-stale case, we already returned above
    sleep "$wait_interval"
    elapsed=$((elapsed + wait_interval))
    if [ "$elapsed" -ge "$max_wait" ]; then
      echo "heal cancelled: could not acquire lock after ${max_wait}s" >&2
      return 1
    fi
  done
}

_release_heal_lock() {
  rm -rf "$_doctor_lock_file" 2>/dev/null
}

# --- Bedrock model override detection ---
# Usage: _detect_bedrock_overrides
# Adds rows for kimi-k3 and deepseek-r1 Bedrock model overrides
# If pi is absent OR SM_CHECKER_HARNESS is not pi, skips entirely (no rows added)
# If PLANNERS array is malformed/unparseable, reports UNKNOWN for each model (NOT silent pass)
_detect_bedrock_overrides() {
  # Skip if pi is not installed/present OR if SM_CHECKER_HARNESS is not pi
  # The Bedrock override check only matters when pi is actually configured as the checker
  local h="${SM_CHECKER_HARNESS:-pi}"
  h="$(printf '%s' "$h" | tr '\n\r|' '   ')"
  if ! have pi || [ "$h" != "pi" ]; then
    return 0
  fi

  # Derive model IDs from bin/plan-committee.sh's PLANNERS array
  local kimi_model_id deepseek_model_id
  
  kimi_model_id=$(_bedrock_get_model_id "kimi-k3") || {
    # Label not found in PLANNERS - UNKNOWN (not silent pass)
    add UNKNOWN "pi Bedrock override: kimi-k3" companion ""
    kimi_model_id=""
  }
  
  deepseek_model_id=$(_bedrock_get_model_id "deepseek-r1") || {
    # Label not found in PLANNERS - UNKNOWN (not silent pass)
    add UNKNOWN "pi Bedrock override: deepseek-r1" companion ""
    deepseek_model_id=""
  }

  # Build models.json path (pi's local user-config file)
  local models_json="$HOME/.pi/agent/models.json"

  # Check kimi-k3 model override
  if [ -n "$kimi_model_id" ]; then
    if _bedrock_validate_kimi_k3 "$models_json" "$kimi_model_id"; then
      add OK "pi Bedrock override: kimi-k3" companion ""
    else
      add MISSING "pi Bedrock override: kimi-k3" companion ""
    fi
  fi

  # Check deepseek-r1 model entry
  if [ -n "$deepseek_model_id" ]; then
    if _bedrock_validate_deepseek_r1 "$models_json" "$deepseek_model_id"; then
      add OK "pi Bedrock override: deepseek-r1" companion ""
    else
      add MISSING "pi Bedrock override: deepseek-r1" companion ""
    fi
  fi
}

# --- Bedrock model override healing ---
# Usage: _heal_bedrock_kimi_k3 <model_id>
_heal_bedrock_kimi_k3() {
  local model_id="$1"
  local models_json="$HOME/.pi/agent/models.json"
  
  if _bedrock_fix_kimi_k3 "$models_json" "$model_id"; then
    echo "[OK] kimi-k3 Bedrock override fixed"
    return 0
  else
    echo "[FAIL] kimi-k3 Bedrock override fix failed"
    return 1
  fi
}

# Usage: _heal_bedrock_deepseek_r1 <model_id>
_heal_bedrock_deepseek_r1() {
  local model_id="$1"
  local models_json="$HOME/.pi/agent/models.json"
  
  if _bedrock_fix_deepseek_r1 "$models_json" "$model_id"; then
    echo "[OK] deepseek-r1 Bedrock override fixed"
    return 0
  else
    echo "[FAIL] deepseek-r1 Bedrock override fix failed"
    return 1
  fi
}

# Usage: _heal_bedrock_overrides <yes_or_not>
# Mediate healing for Bedrock model overrides (special case: need to derive model IDs from PLANNERS)
_heal_bedrock_overrides() {
  local yes="$1"
  local heal_failed=0
  
  # If pi is absent, nothing to heal
  if ! have pi; then
    return 0
  fi

  # Derive model IDs from bin/plan-committee.sh's PLANNERS array
  local kimi_model_id deepseek_model_id
  
  kimi_model_id=$(_bedrock_get_model_id "kimi-k3")
  if [ -z "$kimi_model_id" ]; then
    # Not found in PLANNERS - skip (already reported as UNKNOWN in detect)
    echo "[SKIP] kimi-k3 model not found in PLANNERS array"
  else
    # Only heal if it was reported as MISSING (status is first column: MISSING|name|category|fix)
    # Format: status|name|category|fix, check for MISSING|pi Bedrock override: kimi-k3
    if echo "$ROWS" | grep -q "^MISSING|pi Bedrock override: kimi-k3|"; then
      if [ "$yes" = 1 ]; then
        _heal_bedrock_kimi_k3 "$kimi_model_id" || heal_failed=1
      else
        printf 'Fix pi Bedrock override: kimi-k3 via: %s\n  proceed? [y/N] ' "_heal_bedrock_kimi_k3 $kimi_model_id"
        read -r ans
        case "$ans" in y|Y) _heal_bedrock_kimi_k3 "$kimi_model_id" || heal_failed=1;; *) echo "   skipped";; esac
      fi
    fi
  fi

  deepseek_model_id=$(_bedrock_get_model_id "deepseek-r1")
  if [ -z "$deepseek_model_id" ]; then
    # Not found in PLANNERS - skip (already reported as UNKNOWN in detect)
    echo "[SKIP] deepseek-r1 model not found in PLANNERS array"
  else
    # Only heal if it was reported as MISSING
    if echo "$ROWS" | grep -q "^MISSING|pi Bedrock override: deepseek-r1|"; then
      if [ "$yes" = 1 ]; then
        _heal_bedrock_deepseek_r1 "$deepseek_model_id" || heal_failed=1
      else
        printf 'Fix pi Bedrock override: deepseek-r1 via: %s\n  proceed? [y/N] ' "_heal_bedrock_deepseek_r1 $deepseek_model_id"
        read -r ans
        case "$ans" in y|Y) _heal_bedrock_deepseek_r1 "$deepseek_model_id" || heal_failed=1;; *) echo "   skipped";; esac
      fi
    fi
  fi
  
  [ "$heal_failed" -ne 0 ] && return 1
  return 0
}
# Bug 5 helper: Verify lock is still stale after reading it
# Usage: _is_lock_still_stale <original_timestamp> <max_wait> [original_pid]
# Returns 0 (true) if still stale, 1 (false) if TOCTOU happened or not stale
_is_lock_still_stale() {
  local original_timestamp="$1"
  local max_wait="$2"
  local original_pid="${3:-}"  # Optional third arg: original pid
  
  # Read current timestamp and pid
  local current_timestamp current_pid
  current_timestamp=$(cat "$_doctor_lock_file/.timestamp" 2>/dev/null || echo "")
  current_pid=$(cat "$_doctor_lock_file/.pid" 2>/dev/null || echo "")
  
  # Bug 5 fix: Re-verify the lock hasn't changed since our first read
  # If either value changed, another process modified the lock - DO NOT remove!
  [ -z "$current_timestamp" ] && return 1
  [ -z "$current_pid" ] && return 1
  [ "$current_timestamp" != "$original_timestamp" ] && return 1
  
  # Also verify pid hasn't changed (TOCTOU protection)
  if [ -n "$original_pid" ] && [ "$current_pid" != "$original_pid" ]; then
    return 1
  fi
  
  # Re-check age with the fresh timestamp
  local lock_age
  lock_age=$(( $(date +%s) - current_timestamp ))
  [ "$lock_age" -gt "$max_wait" ] || return 1
  
  # Bug 6 fix: Before treating as stale, verify the PID is actually dead
  # A lock with an old timestamp but a LIVING process is NOT stale
  # The PID file should contain a single numeric PID
  if [ -n "$current_pid" ] && [ "$current_pid" -eq "$current_pid" ] 2>/dev/null; then
    # PID is numeric - check if process is alive using kill -0 (doesn't actually send signal)
    if kill -0 "$current_pid" 2>/dev/null; then
      # Process is alive, so lock is NOT stale (process is still working)
      return 1
    fi
  fi
  # PID is missing, non-numeric, or confirmed dead - treat as stale
  
  # Still stale after re-verification
  return 0
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
  # Use installed_version (from installed_plugins.json) not current_version
  local installed_version new_version
  installed_version=$(python3 -c "
import json,sys
try:
    data=json.load(open(sys.argv[1]))
    plugins=data.get('plugins',{})
    if isinstance(plugins,dict):
        for key,entries in plugins.items():
            if isinstance(entries,list) and len(entries)>0 and isinstance(entries[0],dict):
                if key.startswith('secondmate@'):
                    print(entries[0].get('version',''))
                    sys.exit(0)
except Exception as e:
    pass
print('',end='')
sys.exit(1)
" "$_installed_plugins_json" 2>/dev/null || true)
  new_version=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('version',''))" "$_marketplace_checkout/.claude-plugin/plugin.json" 2>/dev/null || true)
  
  if [ "$installed_version" = "$new_version" ]; then
    echo "[SKIP] claude plugin update is not applicable (version unchanged)"
    echo "       new commits exist but version string was not bumped"
    echo "       run 'claude plugin update secondmate@secondmate' manually to force"
    return 0
  fi
  
  # Get running version for display purposes (unchanged, still used in output)
  local current_version
  current_version=$(python3 -c "import json,sys; print(json.load(open('$plugin_json')).get('version',''))" 2>/dev/null || true)
  
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
    echo "[FAIL] cannot verify heal - secondmate not found in installed_plugins.json"
    echo "       plugin update may have failed or corrupted the file"
    return 1
  fi
  
  local after_version
  after_version=$(python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    plugins=d.get('plugins',{})
    if isinstance(plugins,dict):
        for key,entries in plugins.items():
            if isinstance(entries,list) and len(entries)>0 and isinstance(entries[0],dict):
                if key.startswith('secondmate@'):
                    print(entries[0].get('version',''))
                    sys.exit(0)
except Exception as e:
    pass
print('',end='')
" "$_installed_plugins_json" 2>/dev/null || true)
  
  if [ "$after_sha" = "$remote_sha" ]; then
    echo "[OK] SHA advanced: $local_sha -> $after_sha (version: $current_version -> $after_version)"
  else
    echo "[WARN] SHA did not advance to expected value
       expected: $remote_sha
       got:      $after_sha"
    return 1
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

# --- Skill discovery asymmetry detection (pi vs Claude Code) ---
# Encodes the REAL, verified discovery rules for project-local skills (confirmed against pi's compiled
# source, see bin/sync-worktree-skills.sh's header for the full writeup):
#   Claude Code reads: .claude/skills/<name>  and  .agents/skills/<name>
#   pi               reads: .pi/skills/<name>    and  .agents/skills/<name>
# .agents/skills/ is the one convention both harnesses read directly -- the portable intersection.
# A skill present ONLY under .claude/skills is invisible to a pi maker; ONLY under .pi/skills is
# invisible to a Claude Code maker. This check is deliberately TOP-LEVEL only (no monorepo depth-walk)
# -- it's a quick pre-flight report on the current repo, not an exhaustive scan; the depth-walking
# logic already lives in sync-worktree-skills.sh for the worktree-backfill problem this complements.
#
# Skill names are validated against the exact bare-identifier pattern bin/claim-ledger.py already uses
# for task-id validation ([A-Za-z0-9_-]{1,128}) before EVER being interpolated into a constructed heal
# command -- a directory with a crafted name (shell metacharacters, path separators) is silently
# excluded from every row rather than risking it reaching a shell string. This is a passive filesystem
# scan of names already sitting on disk, not caller-supplied input, so silent exclusion (rather than a
# hard error) is the right failure mode: it must never abort the rest of the report over one odd name.
_SKILL_NAME_SAFE_RE='^[A-Za-z0-9_-]{1,128}$'

_detect_skill_discovery_sync() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$PWD"
  [ -d "$root/.claude/skills" ] || [ -d "$root/.pi/skills" ] || [ -d "$root/.agents/skills" ] || return 0

  local report
  report="$(SM_SKILL_ROOT="$root" python3 << 'PYEOF'
import os, re, sys

root = os.environ['SM_SKILL_ROOT']
NAME_RE = re.compile(r'^[A-Za-z0-9_-]{1,128}$')

def names_in(rel):
    d = os.path.join(root, rel)
    if not os.path.isdir(d):
        return set()
    out = set()
    try:
        entries = os.listdir(d)
    except OSError:
        return set()
    for entry in entries:
        if NAME_RE.match(entry) and os.path.isdir(os.path.join(d, entry)):  # isdir follows symlinks
            out.add(entry)
    return out

claude_only = names_in('.claude/skills')
pi_only = names_in('.pi/skills')
agents = names_in('.agents/skills')

claude_visible = claude_only | agents
pi_visible = pi_only | agents

for name in sorted(claude_visible | pi_visible):
    print(f"{name}\t{int(name in claude_visible)}\t{int(name in pi_visible)}")
PYEOF
)"
  [ -n "$report" ] || return 0

  local name in_claude in_pi
  while IFS=$'\t' read -r name in_claude in_pi; do
    [ -n "$name" ] || continue
    if [ "$in_claude" = 1 ] && [ "$in_pi" = 1 ]; then
      add OK "skill discovery: $name (pi+claude)" companion ""
    elif [ "$in_claude" = 1 ]; then
      add MISSING "skill discovery: $name (not visible to pi)" companion "$(_skill_discovery_heal_fix "$root" "$name")"
    else
      add MISSING "skill discovery: $name (not visible to claude)" companion ""
    fi
  done <<< "$report"
}

# Usage: _skill_discovery_heal_fix <repo-root> <name>
# Prints a safe, idempotent shell command that copies a Claude-only skill's real content into
# .agents/skills/<name> (the portable location pi already reads), so the generic heal() dispatch loop
# below can run it exactly like any other MISSING row's fix command -- no bespoke _heal_* function
# needed. Prints nothing (no auto-fix offered) if it is not safe/unambiguous to do so: the name fails
# the safe-identifier check (defense in depth -- detect() already filtered this), .agents/skills/<name>
# already exists as ANY kind of entry (never offers to clobber), or the resolved real source escapes
# the repo root the same way bin/sync-worktree-skills.sh already guards against for the identical
# reason (a symlink pointing outside the checkout must never have its content copied anywhere).
_skill_discovery_heal_fix() {
  local root="$1" name="$2"
  [[ "$name" =~ $_SKILL_NAME_SAFE_RE ]] || return 0
  local root_p src dst dst_parent resolved
  root_p="$(cd "$root" && pwd -P)" || return 0
  src="$root_p/.claude/skills/$name"
  dst_parent="$root_p/.agents/skills"
  dst="$dst_parent/$name"
  { [ -e "$dst" ] || [ -L "$dst" ]; } && return 0   # already something there -- never offer to clobber
  resolved="$(python3 -c 'import os,sys; p=os.path.realpath(sys.argv[1]); print(p if os.path.isdir(p) else "")' "$src" 2>/dev/null)"
  [ -n "$resolved" ] || return 0
  case "$resolved" in
    "$root_p"|"$root_p"/*) ;;   # inside the repo -- safe to offer
    *) return 0;;               # resolves outside the repo -- never offer (mirrors sync-worktree-skills.sh)
  esac
  printf 'if [ -e %q ] || [ -L %q ]; then echo "already exists, skipping" >&2; else mkdir -p %q && cp -R -p %q %q; fi' \
    "$dst" "$dst" "$dst_parent" "$resolved" "$dst"
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

  # --- Bedrock model override checks ---
  # Notes:
  # - These checks detect and fix missing/incorrect maxTokens overrides for pi's local models.json
  # - Once fixed, the local override permanently shadows any future pi.dev catalog fix (pi's user-config always wins)
  # - The fix is idempotent: running heal multiple times on already-correct values does nothing
  # - If pi is absent, these checks are skipped entirely (no rows added)
  _detect_bedrock_overrides

  # SKILL DISCOVERY ASYMMETRY — a project skill present under .claude/skills/ (or .pi/skills/) only
  # may be invisible to the OTHER maker harness; see _detect_skill_discovery_sync's own comment.
  _detect_skill_discovery_sync

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
    local mark="[ok]"; [ "$st" != OK ] && mark="[!!]"
    printf '%-4s %-38s %-9s %s\n' "$mark" "$name" "$cat" "$fix"
  done <<< "$ROWS"
  echo "----------------------------------------------------------------------"
  echo "note: cross-model checking also needs a 2nd model family + credentials for your harness"
  echo "      (defaults: amazon-bedrock GPT-5.6 / DeepSeek-R1). Set SM_CHECKER_* / SM_REASON_* to yours."
  if [ "$core_missing" -gt 0 ]; then echo "STATUS: not ready. $core_missing core missing. Run: doctor.sh --heal"
  elif [ "$checker_missing" -gt 0 ]; then echo "STATUS: ready via in-session Claude fallback. No external checker harness found; install one (doctor.sh --heal) for a stronger cross-vendor check."
  elif [ "$missing_marketplace_count" -gt 0 ]; then echo "STATUS: ready, but secondmate plugin marketplace checkout is missing (claude plugin marketplace add eshwarvijay/secondmate)"
  elif [ "$unknown_count" -gt 0 ]; then echo "STATUS: ready, but secondmate plugin state is unknown/unverifiable -- check installed_plugins.json"
  elif [ "$stale_count" -gt 0 ]; then echo "STATUS: ready, but secondmate plugin needs healing (doctor.sh --heal)"
  elif [ "$reload_pending_count" -gt 0 ]; then echo "STATUS: ready, but secondmate plugin needs a session reload (claude /reload-plugins)"
  else echo "STATUS: ready (core plus checker harness present)"; fi
}

heal() {
  local yes="$1"
  local heal_failed=0  # Bug 4 fix: track if secondmate heal failed
  
  # Handle secondmate plugin staleness first
  _detect_secondmate_status
  if [ "$_sm_status" = "stale" ] || [ "$_sm_status" = "silent_drift" ] || [ "$_sm_status" = "missing" ]; then
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
    
    # Bug 4 fix: if heal failed, mark it and continue to report all issues
    # But we'll still return 1 at the end if any heal failed
    [ "$heal_result" -ne 0 ] && heal_failed=1
    
    echo
  elif [ "$_sm_status" = "unknown" ]; then
    # Bug 7 fix: unknown state means we cannot determine whether healing is needed/possible
    # Treat this as failure, matching the precedent for Bug 7 (unverifiable = failure, not success)
    echo "=== SECONDMATE PLUGIN HEAL ==="
    echo "[FAIL] cannot determine secondmate plugin state (installed_plugins.json is malformed or unreadable)"
    echo "       please fix installed_plugins.json and re-run"
    return 1
  fi
  
  # Then heal other missing items
  while IFS='|' read -r st name cat fix; do
    [ "$st" = MISSING ] || continue
    # Skip secondmate here since we already handled it above
    [ "$name" = "secondmate plugin (marketplace)" ] && continue
    [ "$name" = "secondmate plugin (stale)" ] && continue
    [ "$name" = "secondmate plugin (silent drift)" ] && continue
    [ "$name" = "secondmate plugin (reload pending)" ] && continue
    # Bug 2 fix: skip Bedrock rows here too - they are handled by bespoke _heal_bedrock_overrides
    [ "$name" = "pi Bedrock override: kimi-k3" ] && continue
    [ "$name" = "pi Bedrock override: deepseek-r1" ] && continue
    [ -z "$fix" ] && { echo "SKIP  $name — no known auto-fix; provide its source (see README) and set the matching SM_* var"; continue; }
    if [ "$yes" = 1 ]; then echo ">> healing $name: $fix"; bash -c "$fix" || echo "   (failed — do it manually: $fix)"
    else
      printf 'Fix %s via: %s\n  proceed? [y/N] ' "$name" "$fix"; read -r ans
      case "$ans" in y|Y) bash -c "$fix" || echo "   (failed — do it manually: $fix)";; *) echo "   skipped";; esac
    fi
  done <<< "$ROWS"

  # Handle Bedrock model override fixes (special case - need to parse the name for model type)
  # Finding 3 fix: wrap with same lock pattern as secondmate heal to prevent concurrent --heal races
  _acquire_heal_lock || {
    echo "Heal not performed."
    return 1
  }
  trap '_release_heal_lock' EXIT
  
  _heal_bedrock_overrides "$yes"
  heal_result=$?
  _release_heal_lock
  trap - EXIT
  
  [ "$heal_result" -ne 0 ] && heal_failed=1
  
  # Bug 4 fix: return failure if secondmate heal failed
  if [ "$heal_failed" -eq 1 ]; then
    return 1
  fi
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

  # === 5-state staleness detection selfcheck ===
  # running_version is read from THIS worktree's actual plugin.json (live, not hardcoded)
  running_version="$version_line"

  # Helper functions for test fixtures
  mk_marketplace() {  # mk_marketplace <dir> <version...for each sequential commit>
    local dir="$1"; shift
    mkdir -p "$dir/.claude-plugin"
    git -C "$dir" init -q -b main 2>/dev/null || true
    git -C "$dir" config user.email t@t.com 2>/dev/null
    git -C "$dir" config user.name t 2>/dev/null
    local v sha=""
    for v in "$@"; do
      printf '{"name":"secondmate","version":"%s"}\n' "$v" > "$dir/.claude-plugin/plugin.json"
      git -C "$dir" add -A 2>/dev/null || true
      git -C "$dir" commit -q -m "v$v" 2>/dev/null || true
      sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
    done
    echo "$sha"
  }
  mk_installed_json() {  # mk_installed_json <path> <sha> <version>
    cat > "$1" <<EOF
{"plugins":{"secondmate@secondmate":[{"scope":"user","installPath":"/tmp/x","version":"$3","gitCommitSha":"$2"}]}}
EOF
  }

  # Test 1: ok state -- sha and version both match
  d=$(mktemp -d)
  sha=$(mk_marketplace "$d/mkt" "$version_line")
  j="$d/plugins.json"
  mk_installed_json "$j" "$sha" "$version_line"
  name=$(SM_SECONDMATE_MARKETPLACE_DIR="$d/mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" "$0" --json 2>/dev/null | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin) if 'secondmate plugin' in x['name']]; print(r[0]['name'] if r else 'UNKNOWN')")
  [ "$name" = "secondmate plugin" ] || { echo "FAIL: expected ok state, got name '$name'"; exit 1; }
  rm -rf "$d"

  # Test 2: stale state -- sha differs, version differs (marketplace ahead)
  d=$(mktemp -d)
  sha=$(mk_marketplace "$d/mkt" "0.1.9")  # marketplace now has version 0.1.9
  j="$d/plugins.json"
  mk_installed_json "$j" "deadbeef00000000000000000000000000000000" "0.1.7"  # old sha, old version
  name=$(SM_SECONDMATE_MARKETPLACE_DIR="$d/mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" "$0" --json 2>/dev/null | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin) if 'secondmate plugin' in x['name']]; print(r[0]['name'] if r else 'UNKNOWN')")
  [ "$name" = "secondmate plugin (stale)" ] || { echo "FAIL: expected stale state, got name '$name'"; exit 1; }
  rm -rf "$d"

  # Test 3: silent_drift state -- sha differs but version unchanged
  d=$(mktemp -d)
  sha=$(mk_marketplace "$d/mkt" "$version_line")
  j="$d/plugins.json"
  mk_installed_json "$j" "deadbeef00000000000000000000000000000000" "$version_line"  # old sha, same version
  name=$(SM_SECONDMATE_MARKETPLACE_DIR="$d/mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" "$0" --json 2>/dev/null | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin) if 'secondmate plugin' in x['name']]; print(r[0]['name'] if r else 'UNKNOWN')")
  [ "$name" = "secondmate plugin (silent drift)" ] || { echo "FAIL: expected silent_drift state, got name '$name'"; exit 1; }
  rm -rf "$d"

  # Test 4: reload_pending state -- sha matches, installed_version differs from running
  d=$(mktemp -d)
  sha=$(mk_marketplace "$d/mkt" "$version_line")
  j="$d/plugins.json"
  mk_installed_json "$j" "$sha" "${version_line}-old"  # guaranteed different from $version_line by construction, not by luck
  name=$(SM_SECONDMATE_MARKETPLACE_DIR="$d/mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" "$0" --json 2>/dev/null | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin) if 'secondmate plugin' in x['name']]; print(r[0]['name'] if r else 'UNKNOWN')")
  [ "$name" = "secondmate plugin (reload pending)" ] || { echo "FAIL: expected reload_pending state, got name '$name'"; exit 1; }
  rm -rf "$d"

  # Test 5: missing state -- marketplace checkout doesn't exist
  d=$(mktemp -d)
  j="$d/plugins.json"
  mk_installed_json "$j" "deadbeef00000000000000000000000000000000" "0.1.7"
  name=$(SM_SECONDMATE_MARKETPLACE_DIR="$d/noexist" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" "$0" --json 2>/dev/null | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin) if 'secondmate plugin' in x['name']]; print(r[0]['name'] if r else 'UNKNOWN')")
  [ "$name" = "secondmate plugin (marketplace)" ] || { echo "FAIL: expected missing state, got name '$name'"; exit 1; }
  rm -rf "$d"

  # === 5 abort-path selfcheck tests for _heal_secondmate ===

  # Test 6: dirty marketplace tree abort
  d=$(mktemp -d)
  sha=$(mk_marketplace "$d/mkt" "$version_line")
  j="$d/plugins.json"
  mk_installed_json "$j" "$sha" "$version_line"
  # make a dirty change without committing
  echo "x" >> "$d/mkt/somefile.txt" 2>/dev/null || echo "initial" > "$d/mkt/somefile.txt"
  echo "x" >> "$d/mkt/somefile.txt"
  # record the dirty file content before calling _heal_secondmate
  dirty_content=$(cat "$d/mkt/somefile.txt")
  # set up origin remote for fetch to succeed
  git -C "$d/mkt" remote add origin /tmp/nonexistent 2>/dev/null || true
  # capture state before
  before_head=$(git -C "$d/mkt" rev-parse HEAD)
  # try to heal (should abort on dirty tree check, before any git fetch/pull)
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$d/mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" bash -c 'source "'$script_abs'"; _heal_secondmate 0' 2>&1)
  rc=$?
  # verify it failed
  [ "$rc" -ne 0 ] || { echo "FAIL: dirty tree test expected non-zero rc, got $rc"; rm -rf "$d"; exit 1; }
  # verify it printed the right message
  echo "$out" | grep -q "\[FAIL\] marketplace checkout has uncommitted changes" || { echo "FAIL: dirty tree test expected [FAIL] about uncommitted changes"; rm -rf "$d"; exit 1; }
  # verify NO git fetch/pull happened (dirty file unchanged and HEAD unchanged)
  after_head=$(git -C "$d/mkt" rev-parse HEAD)
  [ "$before_head" = "$after_head" ] || { echo "FAIL: dirty tree test: HEAD changed from $before_head to $after_head (should not proceed past dirty check)"; rm -rf "$d"; exit 1; }
  rm -rf "$d"

  # Test 7: detached HEAD abort
  d=$(mktemp -d)
  sha=$(mk_marketplace "$d/mkt" "$version_line")
  j="$d/plugins.json"
  mk_installed_json "$j" "$sha" "$version_line"
  # create an origin remote that exists (a bare repo)
  origin_dir=$(mktemp -d)
  git -C "$origin_dir" init -q --bare 2>/dev/null
  git -C "$d/mkt" remote add origin "$origin_dir" 2>/dev/null || true
  # checkout a specific SHA to go into detached HEAD
  git -C "$d/mkt" checkout "$sha" 2>/dev/null || true
  # try to heal (should abort on detached HEAD check)
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$d/mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" bash -c 'source "'$script_abs'"; _heal_secondmate 0' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: detached HEAD test expected non-zero rc, got $rc"; rm -rf "$d" "$origin_dir"; exit 1; }
  echo "$out" | grep -q "\[FAIL\] marketplace checkout is on detached HEAD" || { echo "FAIL: detached HEAD test expected [FAIL] about detached HEAD"; rm -rf "$d" "$origin_dir"; exit 1; }
  rm -rf "$d" "$origin_dir"

  # Test 8: non-fast-forward (diverged history) abort
  d=$(mktemp -d)
  origin_dir=$(mktemp -d)
  # create origin repo with one commit
  mkdir -p "$origin_dir/.claude-plugin"
  git -C "$origin_dir" init -q -b main 2>/dev/null || true
  git -C "$origin_dir" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.7"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.7" 2>/dev/null || true
  origin_sha=$(git -C "$origin_dir" rev-parse HEAD)
  # add a remote to the origin
  git -C "$origin_dir" remote add origin "$origin_dir" 2>/dev/null || true
  # clone origin to create the marketplace checkout
  git clone -q "$origin_dir" "$d/mkt" 2>/dev/null
  # make a local commit on the clone (that doesn't exist on origin)
  echo "local change" >> "$d/mkt/local.txt"
  git -C "$d/mkt" add local.txt 2>/dev/null || true
  git -C "$d/mkt" commit -q -m "local-only" 2>/dev/null || true
  local_sha=$(git -C "$d/mkt" rev-parse HEAD)
  # now advance origin with a new commit (so histories diverge)
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  j="$d/plugins.json"
  mk_installed_json "$j" "$origin_sha" "0.1.7"
  # try to heal (should abort on fast-forward check)
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$d/mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" bash -c 'source "'$script_abs'"; _heal_secondmate 0' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: non-ff test expected non-zero rc, got $rc"; rm -rf "$d" "$origin_dir"; exit 1; }
  echo "$out" | grep -q "\[FAIL\] pull would not be a fast-forward" || { echo "FAIL: non-ff test expected [FAIL] about non-fast-forward"; rm -rf "$d" "$origin_dir"; exit 1; }
  # verify local state unchanged (local commit still there, HEAD unchanged)
  after_head=$(git -C "$d/mkt" rev-parse HEAD)
  [ "$local_sha" = "$after_head" ] || { echo "FAIL: non-ff test: HEAD changed from $local_sha to $after_head"; rm -rf "$d" "$origin_dir"; exit 1; }
  [ -f "$d/mkt/local.txt" ] || { echo "FAIL: non-ff test: local.txt missing (should be preserved)"; rm -rf "$d" "$origin_dir"; exit 1; }
  rm -rf "$d" "$origin_dir"

  # Test 9: marketplace checkout directory missing
  d=$(mktemp -d)
  j="$d/plugins.json"
  mk_installed_json "$j" "deadbeef00000000000000000000000000000000" "0.1.7"
  # try to heal with nonexistent checkout directory
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$d/nonexistent" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" bash -c 'source "'$script_abs'"; _heal_secondmate 0' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: missing dir test expected non-zero rc, got $rc"; rm -rf "$d"; exit 1; }
  echo "$out" | grep -q "\[FAIL\] secondmate marketplace checkout not found" || { echo "FAIL: missing dir test expected [FAIL] about checkout not found"; rm -rf "$d"; exit 1; }
  # verify it printed the fix command
  echo "$out" | grep -q "claude plugin marketplace add eshwarvijay/secondmate" || { echo "FAIL: missing dir test should print the fix command"; rm -rf "$d"; exit 1; }
  rm -rf "$d"

  # Test 10: claude not resolvable (PATH without claude)
  d=$(mktemp -d)
  sha=$(mk_marketplace "$d/mkt" "0.1.8")
  j="$d/plugins.json"
  mk_installed_json "$j" "$sha" "0.1.8"
  # create a fake PATH without claude
  fake_path="/usr/bin:/bin"
  # try to heal with PATH that has no claude
  # We need to capture the script path for sourcing
  script_abs_for_source="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  # IMPORTANT: need to use export or explicit PATH for EACH command since PATH=/path prefix only applies to immediate command
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$d/mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" bash -c "export PATH='$fake_path'; source $script_abs_for_source; _heal_secondmate 0" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: no-claude test expected non-zero rc, got $rc"; rm -rf "$d"; exit 1; }
  echo "$out" | grep -q "\[FAIL\] claude CLI not found" || { echo "FAIL: no-claude test expected [FAIL] about claude not found"; echo "DEBUG output was:"; echo "$out" >&2; rm -rf "$d"; exit 1; }
  rm -rf "$d"

  # === Test A: successful heal path (real origin repo, real fetch+ff-only pull, stub claude binary) ===
  d=$(mktemp -d)
  origin_dir=$(mktemp -d)
  checkout_dir="$d/mkt"
  stub_dir=$(mktemp -d)
  j="$d/plugins.json"

  # Create origin repo with first commit (version 0.1.7)
  mkdir -p "$origin_dir/.claude-plugin"
  git -C "$origin_dir" init -q -b main 2>/dev/null || true
  git -C "$origin_dir" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.7"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.7" 2>/dev/null || true
  origin_sha_1=$(git -C "$origin_dir" rev-parse HEAD)

  # Clone origin to create marketplace checkout
  git clone -q "$origin_dir" "$checkout_dir" 2>/dev/null

  # Advance origin with second commit (version 0.1.9)
  printf '{"name":"secondmate","version":"0.1.9"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.9" 2>/dev/null || true
  origin_sha_2=$(git -C "$origin_dir" rev-parse HEAD)

  # Write installed_plugins.json with OLD sha and version
  mk_installed_json "$j" "$origin_sha_1" "0.1.7"

  # Create stub claude binary that rewrites installed_plugins.json when called correctly
  # USE QUOTED heredoc delimiter so $1/$2 are NOT expanded when WRITING the file
  cat > "$stub_dir/claude" << 'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "$1" = "plugin" ] && [ "$2" = "update" ] && [ "$3" = "secondmate@secondmate" ] && [ "$4" = "-y" ]; then
  if [ -n "$SM_TEST_INSTALLED_JSON_FOR_STUB" ] && [ -f "$SM_TEST_INSTALLED_JSON_FOR_STUB" ]; then
    # Get new sha from origin repo
    origin_sha=$(git -C "$SM_SECONDMATE_MARKETPLACE_DIR" rev-parse HEAD 2>/dev/null || true)
    origin_ver=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('version',''))" "$SM_SECONDMATE_MARKETPLACE_DIR/.claude-plugin/plugin.json" 2>/dev/null || true)
    # Rewrite installed_plugins.json with new sha and version
    python3 -c "
import json,sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    plugins = data.get('plugins', {})
    if isinstance(plugins, dict):
        for key in list(plugins.keys()):
            if key.startswith('secondmate@'):
                entries = plugins[key]
                if isinstance(entries, list) and len(entries) > 0 and isinstance(entries[0], dict):
                    entries[0]['gitCommitSha'] = '$origin_sha'
                    entries[0]['version'] = '$origin_ver'
    with open(sys.argv[1], 'w') as f:
        json.dump(data, f)
except Exception as e:
    import sys
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" "$SM_TEST_INSTALLED_JSON_FOR_STUB"
  fi
  exit 0
else
  echo "stub claude: unexpected args: $*" >&2
  exit 1
fi
STUB_EOF
  chmod +x "$stub_dir/claude"

  # Record checkout HEAD before heal
  before_checkout_head=$(git -C "$checkout_dir" rev-parse HEAD)

  # Run _heal_secondmate with stub in PATH
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" SM_TEST_INSTALLED_JSON_FOR_STUB="$j" PATH="$stub_dir:$PATH" bash -c 'source "'"$script_abs"'"; _heal_secondmate 1' 2>&1)
  rc=$?

  # Assert: return code 0
  [ "$rc" -eq 0 ] || { echo "FAIL: Test A heal test expected rc=0, got $rc"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Assert: checkout HEAD now equals origin's new HEAD (proving real fetch+ff-only pull happened)
  after_checkout_head=$(git -C "$checkout_dir" rev-parse HEAD)
  [ "$after_checkout_head" = "$origin_sha_2" ] || { echo "FAIL: Test A heal test: checkout HEAD $after_checkout_head != origin HEAD $origin_sha_2"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Assert: installed_plugins.json shows new sha/version (proving stub was invoked)
  after_sha=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); p=d.get('plugins',{}); [print(e.get('gitCommitSha','')) for k,v in p.items() if isinstance(v,list) for e in v if isinstance(e,dict) and k.startswith('secondmate@')]" "$j" 2>/dev/null)
  after_ver=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); p=d.get('plugins',{}); [print(e.get('version','')) for k,v in p.items() if isinstance(v,list) for e in v if isinstance(e,dict) and k.startswith('secondmate@')]" "$j" 2>/dev/null)
  [ "$after_sha" = "$origin_sha_2" ] || { echo "FAIL: Test A heal test: installed_plugins.json sha $after_sha != expected $origin_sha_2"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }
  [ "$after_ver" = "0.1.9" ] || { echo "FAIL: Test A heal test: installed_plugins.json version $after_ver != expected 0.1.9"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  rm -rf "$d" "$origin_dir" "$stub_dir"

  # === Test B: silent-drift skip path (version unchanged, claude stub should NOT be called) ===
  d=$(mktemp -d)
  origin_dir=$(mktemp -d)
  checkout_dir="$d/mkt"
  stub_dir=$(mktemp -d)
  j="$d/plugins.json"

  # Create origin repo with first commit (version 0.1.8)
  mkdir -p "$origin_dir/.claude-plugin"
  git -C "$origin_dir" init -q -b main 2>/dev/null || true
  git -C "$origin_dir" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  origin_sha_1=$(git -C "$origin_dir" rev-parse HEAD)

  # Clone origin to create marketplace checkout
  git clone -q "$origin_dir" "$checkout_dir" 2>/dev/null

  # Advance origin with new commit (same version, different file content)
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  echo "new file" > "$origin_dir/newfile.txt"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "add newfile" 2>/dev/null || true
  origin_sha_2=$(git -C "$origin_dir" rev-parse HEAD)

  # Write installed_plugins.json with OLD sha but SAME version 0.1.8
  mk_installed_json "$j" "$origin_sha_1" "0.1.8"

  # Create stub claude binary that would FAIL if called (proves it wasn't)
  cat > "$stub_dir/claude" << 'STUB_EOF'
#!/usr/bin/env bash
echo "stub claude SHOULD NOT BE CALLED - this is a silent drift scenario" >&2
exit 1
STUB_EOF
  chmod +x "$stub_dir/claude"

  # Record checkout HEAD before heal
  before_checkout_head=$(git -C "$checkout_dir" rev-parse HEAD)

  # Run _heal_secondmate with stub in PATH
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" PATH="$stub_dir:$PATH" bash -c 'source "'"$script_abs"'"; _heal_secondmate 1' 2>&1)
  rc=$?

  # Assert: return code 0 (graceful skip, not failure)
  [ "$rc" -eq 0 ] || { echo "FAIL: Test B silent-drift test expected rc=0, got $rc"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Assert: checkout HEAD advanced (git pull DID happen since new commits exist)
  after_checkout_head=$(git -C "$checkout_dir" rev-parse HEAD)
  [ "$after_checkout_head" = "$origin_sha_2" ] || { echo "FAIL: Test B silent-drift test: checkout HEAD $after_checkout_head != origin HEAD $origin_sha_2"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Assert: stub was NEVER invoked (check by stdout not containing error message about not being called)
  echo "$out" | grep -q "SHOULD NOT BE CALLED" && { echo "FAIL: Test B silent-drift test: stub claude WAS called but shouldn't have been"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Assert: [SKIP] message about version unchanged appears
  echo "$out" | grep -q "\[SKIP\] claude plugin update is not applicable" || { echo "FAIL: Test B silent-drift test: expected [SKIP] message about version unchanged"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  rm -rf "$d" "$origin_dir" "$stub_dir"

  # === Test C: lock contention (pre-created lock directory blocks _acquire_heal_lock) ===
  # Note: With Bug 3 fix, a non-stale lock will now fail immediately (correct behavior)
  # because we now check staleness even when lock already exists (fixing the TOCTOU bug)
  d=$(mktemp -d)
  lock_dir="$d/lock"
  lock_file="$lock_dir/secondmate-heal.lock"

  # Pre-create lock directory with a fresh timestamp (non-stale)
  mkdir -p "$lock_file"
  echo "$$" > "$lock_file/.pid"
  echo "$(date +%s)" > "$lock_file/.timestamp"

  # Run _acquire_heal_lock with pre-existing lock (call directly, no subshell needed)
  # Temporarily set _doctor_lock_dir to our test path
  _old_lock_dir="$_doctor_lock_dir"
  _doctor_lock_dir="$lock_dir"
  _doctor_lock_file="$_doctor_lock_dir/secondmate-heal.lock"
  
  out=$(_acquire_heal_lock 2>&1)
  rc=$?
  
  _doctor_lock_dir="$_old_lock_dir"

  # Assert: returns non-zero (lock contention - lock exists and not stale)
  [ "$rc" -ne 0 ] || { echo "FAIL: Test C lock contention test expected non-zero rc, got $rc"; rm -rf "$d"; exit 1; }

  # Assert: error message indicates lock contention (lock was not stale, so fail immediately)
  echo "$out" | grep -q "another heal is already in progress" || { echo "FAIL: Test C lock contention test: expected lock contention error message"; echo "output: $out" >&2; rm -rf "$d"; exit 1; }

  # Verify lock directory contents were not corrupted (still has .pid and .timestamp)
  [ -f "$lock_file/.pid" ] || { echo "FAIL: Test C lock contention test: .pid file missing after contention"; rm -rf "$d"; exit 1; }
  [ -f "$lock_file/.timestamp" ] || { echo "FAIL: Test C lock contention test: .timestamp file missing after contention"; rm -rf "$d"; exit 1; }

  rm -rf "$d"

  # === Test D1 (Bug 1 fix): marketplace checkout with real version bump should report "stale", not "silent_drift"
  # This reproduces the realistic scenario from the issue description:
  # - marketplace checkout has gone from 0.1.8 to 0.1.9 via local commits (no remote needed)
  # - installed_plugins.json still has the old sha/version (0.1.8)
  # - Running doctor.sh from within that same marketplace checkout should report "stale"
  #   (because a real version bump occurred), NOT "silent_drift"
  d=$(mktemp -d)
  mkt_dir="$d/mkt"
  j="$d/plugins.json"

  # Create marketplace checkout with version 0.1.8
  mkdir -p "$mkt_dir/.claude-plugin"
  git -C "$mkt_dir" init -q -b main 2>/dev/null || true
  git -C "$mkt_dir" config user.email t@t.com 2>/dev/null
  git -C "$mkt_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$mkt_dir/.claude-plugin/plugin.json"
  git -C "$mkt_dir" add -A 2>/dev/null || true
  git -C "$mkt_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  old_sha=$(git -C "$mkt_dir" rev-parse HEAD)

  # Advance locally with version 0.1.9 (no remote needed - this is the key scenario)
  printf '{"name":"secondmate","version":"0.1.9"}\n' > "$mkt_dir/.claude-plugin/plugin.json"
  echo "new content" >> "$mkt_dir/readme.md"
  git -C "$mkt_dir" add -A 2>/dev/null || true
  git -C "$mkt_dir" commit -q -m "v0.1.9" 2>/dev/null || true
  new_sha=$(git -C "$mkt_dir" rev-parse HEAD)

  # installed_plugins.json has the old sha/version
  mk_installed_json "$j" "$old_sha" "0.1.8"

  # Run doctor.sh --json with the marketplace checkout as the running script location
  # The plugin_json inside the script points to $mkt_dir/.claude-plugin/plugin.json
  # which now has version 0.1.9 (same as marketplace)
  name=$(SM_SECONDMATE_MARKETPLACE_DIR="$mkt_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" "$0" --json 2>/dev/null | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin) if 'secondmate plugin' in x['name']]; print(r[0]['name'] if r else 'UNKNOWN')")
  
  # The bug would say "silent_drift" because running_version == marketplace_version
  # The fix should say "stale" because installed_version != marketplace_version
  [ "$name" = "secondmate plugin (stale)" ] || { echo "FAIL: Test D1 bug1 fix: expected 'secondmate plugin (stale)', got '$name'"; rm -rf "$d"; exit 1; }
  
  # Also verify the other direction still works: no version change (true silent_drift)
  # Now set installed_plugins.json to have the same version as marketplace
  mk_installed_json "$j" "$old_sha" "0.1.9"  # same version as marketplace
  name=$(SM_SECONDMATE_MARKETPLACE_DIR="$mkt_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" "$0" --json 2>/dev/null | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin) if 'secondmate plugin' in x['name']]; print(r[0]['name'] if r else 'UNKNOWN')")
  [ "$name" = "secondmate plugin (silent drift)" ] || { echo "FAIL: Test D1 bug1 fix: expected 'secondmate plugin (silent drift)', got '$name'"; rm -rf "$d"; exit 1; }
  
  rm -rf "$d"

  # === Test D2 (Bug 2 fix): heal verification rejects wrong SHA, not just any changed SHA ===
  # Create a stub claude that writes a RANDOM wrong SHA (not the remote HEAD) to installed_plugins.json
  d=$(mktemp -d)
  origin_dir=$(mktemp -d)
  checkout_dir="$d/mkt"
  stub_dir=$(mktemp -d)
  j="$d/plugins.json"

  # Create origin repo with version 0.1.8
  mkdir -p "$origin_dir/.claude-plugin"
  git -C "$origin_dir" init -q -b main 2>/dev/null || true
  git -C "$origin_dir" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  origin_sha=$(git -C "$origin_dir" rev-parse HEAD)

  # Clone origin to create marketplace checkout
  git clone -q "$origin_dir" "$checkout_dir" 2>/dev/null

  # Create stub claude that writes a WRONG SHA (not origin_sha) when called
  cat > "$stub_dir/claude" << 'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "$1" = "plugin" ] && [ "$2" = "update" ] && [ "$3" = "secondmate@secondmate" ] && [ "$4" = "-y" ]; then
  # Write a completely wrong SHA (not the real remote HEAD)
  wrong_sha="deadbeef11111111111111111111111111111111"
  python3 -c "
import json,sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    plugins = data.get('plugins', {})
    if isinstance(plugins, dict):
        for key in list(plugins.keys()):
            if key.startswith('secondmate@'):
                entries = plugins[key]
                if isinstance(entries, list) and len(entries) > 0 and isinstance(entries[0], dict):
                    entries[0]['gitCommitSha'] = '$wrong_sha'
    with open(sys.argv[1], 'w') as f:
        json.dump(data, f)
except Exception as e:
    import sys
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" "$SM_TEST_INSTALLED_JSON_FOR_STUB"
  exit 0
else
  echo "stub claude: unexpected args: $*" >&2
  exit 1
fi
STUB_EOF
  chmod +x "$stub_dir/claude"

  # Write installed_plugins.json with old sha
  mk_installed_json "$j" "aaaaaaaa00000000000000000000000000000000" "0.1.7"

  # Run heal with stub in PATH
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" SM_TEST_INSTALLED_JSON_FOR_STUB="$j" PATH="$stub_dir:$PATH" bash -c 'source "'"$script_abs"'"; _heal_secondmate 1' 2>&1)
  rc=$?

  # With Bug 2 fix: should FAIL because after_sha (deadbeef...) != remote_sha (origin_sha)
  [ "$rc" -ne 0 ] || { echo "FAIL: Test D2 bug2 fix: heal should have failed (wrong SHA written), got rc=$rc"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Verify the warning message mentions the expected vs actual SHA
  echo "$out" | grep -q "SHA did not advance to expected value" || { echo "FAIL: Test D2 bug2 fix: expected warning about expected vs actual SHA"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }
  echo "$out" | grep -q "expected: $origin_sha" || { echo "FAIL: Test D2 bug2 fix: expected warning to show correct remote_sha"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }
  echo "$out" | grep -q "got:.*deadbeef" || { echo "FAIL: Test D2 bug2 fix: expected warning to show wrong SHA"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  rm -rf "$d" "$origin_dir" "$stub_dir"

  # === Test D3 (Bug 3 fix): pre-created stale lock should be stolen ===
  # This tests the real fix: the lock loop should now handle pre-existing stale locks
  d=$(mktemp -d)
  lock_dir="$d/lock"
  lock_file="$lock_dir/secondmate-heal.lock"

  # Pre-create lock directory with a STALE timestamp (older than max_wait=30 seconds)
  mkdir -p "$lock_file"
  echo "$$_" > "$lock_file/.pid"
  old_timestamp=$(( $(date +%s) - 60 ))  # 60 seconds ago, definitely stale
  echo "$old_timestamp" > "$lock_file/.timestamp"

  # Run _acquire_heal_lock - with the fix, it should steal the lock and return 0
  _old_lock_dir="$_doctor_lock_dir"
  _doctor_lock_dir="$lock_dir"
  _doctor_lock_file="$_doctor_lock_dir/secondmate-heal.lock"
  
  out=$(_acquire_heal_lock 2>&1)
  rc=$?
  
  _doctor_lock_dir="$_old_lock_dir"

  # With Bug 3 fix: should succeed (return 0) because the stale lock was stolen
  [ "$rc" -eq 0 ] || { echo "FAIL: Test D3 bug3 fix: should have stolen stale lock, got rc=$rc"; echo "output: $out" >&2; rm -rf "$d"; exit 1; }

  # Verify new lock was created with fresh timestamp
  [ -d "$lock_file" ] || { echo "FAIL: Test D3 bug3 fix: lock directory doesn't exist after steal"; rm -rf "$d"; exit 1; }
  [ -f "$lock_file/.pid" ] || { echo "FAIL: Test D3 bug3 fix: .pid file missing after steal"; rm -rf "$d"; exit 1; }
  [ -f "$lock_file/.timestamp" ] || { echo "FAIL: Test D3 bug3 fix: .timestamp file missing after steal"; rm -rf "$d"; exit 1; }
  
  # Verify the timestamp is now fresh (not the old stale one)
  new_ts=$(cat "$lock_file/.timestamp" 2>/dev/null || echo "")
  [ -n "$new_ts" ] || { echo "FAIL: Test D3 bug3 fix: couldn't read timestamp after steal"; rm -rf "$d"; exit 1; }
  [ "$new_ts" -gt "$old_timestamp" ] || { echo "FAIL: Test D3 bug3 fix: timestamp wasn't updated"; rm -rf "$d"; exit 1; }

  rm -rf "$d"

  # === Test E (Bug 5 fix): _is_lock_still_stale re-verification during TOCTOU window ===
  # Test without using mkfifo, background jobs, or wait - just sequential file ops
  # This directly tests the helper function that prevents TOCTOU race
  d=$(mktemp -d)
  lock_dir="$d/lock"
  lock_file="$lock_dir/secondmate-heal.lock"
  
  # Create a lock with a stale timestamp
  mkdir -p "$lock_file"
  old_ts=$(( $(date +%s) - 60 ))
  echo "$old_ts" > "$lock_file/.timestamp"
  echo "12345" > "$lock_file/.pid"
  
  # Temporarily set _doctor_lock_file for the helper
  _old_lock_file="$_doctor_lock_file"
  _doctor_lock_file="$lock_file"
  
  # Test E1: _is_lock_still_stale returns 0 (success) when nothing changed
  # Read the timestamp and pid once, then call the helper (which re-reads and compares)
  first_read_ts=$(cat "$lock_file/.timestamp")
  first_read_pid=$(cat "$lock_file/.pid")  # Save original pid
  out=$(_is_lock_still_stale "$first_read_ts" 30 "$first_read_pid" 2>&1)
  rc=$?
  
  [ "$rc" -eq 0 ] || { echo "FAIL: Test E1 bug5 fix: _is_lock_still_stale should return 0 when nothing changed, got $rc"; rm -rf "$d"; exit 1; }
  
  # Test E2: _is_lock_still_stale returns 1 (failure) when TOCTOU happened
  # Simulate another process modifying the lock between our reads
  first_read_ts=$(cat "$lock_file/.timestamp")
  # Write a NEW value (simulating TOCTOU - another process stole/updated the lock)
  new_ts=$(( $(date +%s) - 5 ))  # Not stale anymore
  echo "$new_ts" > "$lock_file/.timestamp"  # <-- This is the TOCTOU window simulation
  out=$(_is_lock_still_stale "$first_read_ts" 30 "$first_read_pid" 2>&1)
  rc=$?
  
  [ "$rc" -eq 1 ] || { echo "FAIL: Test E2 bug5 fix: _is_lock_still_stale should return 1 when TOCTOU happened (timestamp changed), got $rc"; rm -rf "$d"; exit 1; }
  
  # Test E3: _is_lock_still_stale returns 1 when pid changed (another kind of TOCTOU)
  # Reset the timestamp to stale
  old_ts2=$(( $(date +%s) - 60 ))
  echo "$old_ts2" > "$lock_file/.timestamp"
  first_read_ts=$(cat "$lock_file/.timestamp")
  first_read_pid=$(cat "$lock_file/.pid")  # Save original pid
  # Simulate another process changing only the pid
  echo "99999" > "$lock_file/.pid"  # <-- PID changed, TOCTOU detected
  # Pass original pid as third argument
  out=$(_is_lock_still_stale "$first_read_ts" 30 "$first_read_pid" 2>&1)
  rc=$?
  
  [ "$rc" -eq 1 ] || { echo "FAIL: Test E3 bug5 fix: _is_lock_still_stale should return 1 when pid changed (TOCTOU), got $rc"; rm -rf "$d"; exit 1; }
  
  _doctor_lock_file="$_old_lock_file"
  rm -rf "$d"

  # === Test E: real doctor.sh subprocess heal failure (Bug 4 fix) ===
  # This test invokes the ACTUAL doctor.sh script as a real subprocess with --heal --yes
  # It verifies that when heal fails (stub claude writes wrong SHA), the PROCESS exits non-zero
  # This is the ONE THING that was never actually checked: does running doctor.sh as a real command,
  # when a heal fails, actually exit non-zero?
  # Also tests that when heal SUCCEEDS, the process still exits 0.
  d=$(mktemp -d)
  origin_dir=$(mktemp -d)
  checkout_dir="$d/mkt"
  stub_dir=$(mktemp -d)
  j="$d/plugins.json"
  lock_dir="$d/lock"

  # Create origin repo with first commit (version 0.1.8)
  mkdir -p "$origin_dir/.claude-plugin"
  git -C "$origin_dir" init -q -b main 2>/dev/null || true
  git -C "$origin_dir" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  origin_sha_1=$(git -C "$origin_dir" rev-parse HEAD)

  # Clone origin to create marketplace checkout
  git clone -q "$origin_dir" "$checkout_dir" 2>/dev/null

  # Advance origin with second commit (version 0.1.9)
  printf '{"name":"secondmate","version":"0.1.9"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.9" 2>/dev/null || true
  origin_sha_2=$(git -C "$origin_dir" rev-parse HEAD)

  # Write installed_plugins.json with OLD sha but version 0.1.8
  # This creates the "stale" state: SHA differs AND version differs (0.1.8 != 0.1.9)
  mk_installed_json "$j" "deadbeef00000000000000000000000000000000" "0.1.8"

  # Create stub claude binary that writes WRONG SHA (simulating failed heal)
  cat > "$stub_dir/claude" << 'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "$1" = "plugin" ] && [ "$2" = "update" ] && [ "$3" = "secondmate@secondmate" ] && [ "$4" = "-y" ]; then
  if [ -n "$SM_TEST_INSTALLED_JSON_FOR_STUB" ] && [ -f "$SM_TEST_INSTALLED_JSON_FOR_STUB" ]; then
    # Write WRONG sha - simulating a failed update that doesn't actually update
    python3 -c "
import json,sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    plugins = data.get('plugins', {})
    if isinstance(plugins, dict):
        for key in list(plugins.keys()):
            if key.startswith('secondmate@'):
                entries = plugins[key]
                if isinstance(entries, list) and len(entries) > 0 and isinstance(entries[0], dict):
                    entries[0]['gitCommitSha'] = '0000000000000000000000000000000000000000'  # WRONG SHA
    with open(sys.argv[1], 'w') as f:
        json.dump(data, f)
except Exception as e:
    import sys
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" "$SM_TEST_INSTALLED_JSON_FOR_STUB"
  fi
  exit 0
else
  echo "stub claude: unexpected args: $*" >&2
  exit 1
fi
STUB_EOF
  chmod +x "$stub_dir/claude"

  # Record checkout HEAD before heal
  before_checkout_head=$(git -C "$checkout_dir" rev-parse HEAD)

  # Run REAL doctor.sh as subprocess with --heal --yes (NOT sourcing _heal_secondmate directly)
  # This is the critical difference from earlier tests
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" SM_TEST_INSTALLED_JSON_FOR_STUB="$j" PATH="$stub_dir:$PATH" "$script_abs" --heal --yes 2>&1)
  heal_fail_rc=$?

  # Assert: process exit code non-zero (Bug 4 fix)
  [ "$heal_fail_rc" -ne 0 ] || { echo "FAIL: Test E heal failure test expected non-zero exit code, got $heal_fail_rc"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Assert: installed_plugins.json still has old SHA (heal didn't update it)
  after_sha=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); p=d.get('plugins',{}); [print(e.get('gitCommitSha','')) for k,v in p.items() if isinstance(v,list) for e in v if isinstance(e,dict) and k.startswith('secondmate@')]" "$j" 2>/dev/null)
  [ "$after_sha" = "0000000000000000000000000000000000000000" ] || { echo "FAIL: Test E heal failure test: installed_plugins.json sha $after_sha != expected wrong SHA"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # === Test E2: real doctor.sh subprocess heal success (happy path) ===
  # Now test that when heal SUCCEEDS (stub claude writes CORRECT SHA), the process exits 0
  d2=$(mktemp -d)
  origin_dir2=$(mktemp -d)
  checkout_dir2="$d2/mkt"
  stub_dir2=$(mktemp -d)
  j2="$d2/plugins.json"
  lock_dir2="$d2/lock"

  # Create origin repo with first commit (version 0.1.7)
  mkdir -p "$origin_dir2/.claude-plugin"
  git -C "$origin_dir2" init -q -b main 2>/dev/null || true
  git -C "$origin_dir2" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir2" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir2/.claude-plugin/plugin.json"
  git -C "$origin_dir2" add -A 2>/dev/null || true
  git -C "$origin_dir2" commit -q -m "v0.1.8" 2>/dev/null || true
  origin_sha_1=$(git -C "$origin_dir2" rev-parse HEAD)

  # Clone origin to create marketplace checkout
  git clone -q "$origin_dir2" "$checkout_dir2" 2>/dev/null

  # Advance origin with second commit (version 0.1.9)
  printf '{"name":"secondmate","version":"0.1.9"}\n' > "$origin_dir2/.claude-plugin/plugin.json"
  git -C "$origin_dir2" add -A 2>/dev/null || true
  git -C "$origin_dir2" commit -q -m "v0.1.9" 2>/dev/null || true
  origin_sha_2=$(git -C "$origin_dir2" rev-parse HEAD)

  # Write installed_plugins.json with OLD sha but version 0.1.8
  # This creates the "stale" state: SHA differs AND versions differ (0.1.8 != 0.1.9)
  mk_installed_json "$j2" "deadbeef00000000000000000000000000000000" "0.1.8"

  # Create stub claude binary that writes CORRECT SHA (simulating successful heal)
  cat > "$stub_dir2/claude" << 'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "$1" = "plugin" ] && [ "$2" = "update" ] && [ "$3" = "secondmate@secondmate" ] && [ "$4" = "-y" ]; then
  if [ -n "$SM_TEST_INSTALLED_JSON_FOR_STUB" ] && [ -f "$SM_TEST_INSTALLED_JSON_FOR_STUB" ]; then
    # Get new sha from origin repo and write CORRECT SHA
    origin_sha=$(git -C "$SM_SECONDMATE_MARKETPLACE_DIR" rev-parse HEAD 2>/dev/null || true)
    origin_ver=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('version',''))" "$SM_SECONDMATE_MARKETPLACE_DIR/.claude-plugin/plugin.json" 2>/dev/null || true)
    python3 -c "
import json,sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    plugins = data.get('plugins', {})
    if isinstance(plugins, dict):
        for key in list(plugins.keys()):
            if key.startswith('secondmate@'):
                entries = plugins[key]
                if isinstance(entries, list) and len(entries) > 0 and isinstance(entries[0], dict):
                    entries[0]['gitCommitSha'] = '$origin_sha'
                    entries[0]['version'] = '$origin_ver'
    with open(sys.argv[1], 'w') as f:
        json.dump(data, f)
except Exception as e:
    import sys
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" "$SM_TEST_INSTALLED_JSON_FOR_STUB"
  fi
  exit 0
else
  echo "stub claude: unexpected args: $*" >&2
  exit 1
fi
STUB_EOF
  chmod +x "$stub_dir2/claude"

  # Record checkout HEAD before heal
  before_checkout_head=$(git -C "$checkout_dir2" rev-parse HEAD)

  # Run REAL doctor.sh as subprocess with --heal --yes
  out2=$(SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir2" SM_INSTALLED_PLUGINS_JSON="$j2" SM_DOCTOR_LOCK_DIR="$lock_dir2" SM_TEST_INSTALLED_JSON_FOR_STUB="$j2" PATH="$stub_dir2:$PATH" "$script_abs" --heal --yes 2>&1)
  heal_success_rc=$?

  # Assert: process exit code 0 (happy path)
  [ "$heal_success_rc" -eq 0 ] || { echo "FAIL: Test E2 heal success test expected exit code 0, got $heal_success_rc"; echo "output: $out2" >&2; rm -rf "$d2" "$origin_dir2" "$stub_dir2"; exit 1; }

  # Assert: installed_plugins.json shows new sha/version (proving stub was invoked correctly)
  after_sha2=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); p=d.get('plugins',{}); [print(e.get('gitCommitSha','')) for k,v in p.items() if isinstance(v,list) for e in v if isinstance(e,dict) and k.startswith('secondmate@')]" "$j2" 2>/dev/null)
  after_ver2=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); p=d.get('plugins',{}); [print(e.get('version','')) for k,v in p.items() if isinstance(v,list) for e in v if isinstance(e,dict) and k.startswith('secondmate@')]" "$j2" 2>/dev/null)
  [ "$after_sha2" = "$origin_sha_2" ] || { echo "FAIL: Test E2 heal success test: installed_plugins.json sha $after_sha2 != expected $origin_sha_2"; rm -rf "$d2" "$origin_dir2" "$stub_dir2"; exit 1; }
  [ "$after_ver2" = "0.1.9" ] || { echo "FAIL: Test E2 heal success test: installed_plugins.json version $after_ver2 != expected 0.1.9"; rm -rf "$d2" "$origin_dir2" "$stub_dir2"; exit 1; }

  rm -rf "$d" "$origin_dir" "$stub_dir" "$d2" "$origin_dir2" "$stub_dir2"

  # === Test F1 (Bug 6 fix): _is_lock_still_stale with real live PID ===
  # A lock with an old timestamp but a LIVING process should NOT be treated as stale
  d=$(mktemp -d)
  lock_dir="$d/lock"
  lock_file="$lock_dir/secondmate-heal.lock"

  # Spawn a real background sleep process and get its PID
  sleep 300 &
  alive_pid=$!
  # Give the process a moment to start
  sleep 0.2

  # Create a lock with the live PID and old timestamp
  mkdir -p "$lock_file"
  old_ts=$(( $(date +%s) - 60 ))  # 60 seconds ago, definitely stale by age
  echo "$old_ts" > "$lock_file/.timestamp"
  echo "$alive_pid" > "$lock_file/.pid"

  # Temporarily set _doctor_lock_file for the helper
  _old_lock_file="$_doctor_lock_file"
  _doctor_lock_file="$lock_file"

  # Call _is_lock_still_stale - should return 1 (NOT stale) because PID is alive
  out=$(_is_lock_still_stale "$old_ts" 30 "$alive_pid" 2>&1)
  rc=$?

  # With Bug 6 fix: should return 1 (lock not stale - process is alive)
  [ "$rc" -eq 1 ] || { echo "FAIL: Test F1 bug6 fix: _is_lock_still_stale should return 1 for live PID, got $rc"; kill "$alive_pid" 2>/dev/null; wait "$alive_pid" 2>/dev/null; rm -rf "$d"; exit 1; }

  # Kill the live PID process immediately after the assertion that needs it alive
  kill "$alive_pid" 2>/dev/null
  wait "$alive_pid" 2>/dev/null

  # Also test with a DEAD PID (same timestamp but PID that doesn't exist)
  # Write dead PID to file (not using the already-killed process)
  fake_dead_pid=999999
  echo "$fake_dead_pid" > "$lock_file/.pid"

  # Call _is_lock_still_stale with the same old timestamp and dead PID
  out=$(_is_lock_still_stale "$old_ts" 30 "$fake_dead_pid" 2>&1)
  rc=$?

  # With Bug 6 fix: should return 0 (stale) because PID is dead/nonexistent
  # Note: kill -0 returns non-zero if process doesn't exist
  [ "$rc" -eq 0 ] || { echo "FAIL: Test F1 companion: _is_lock_still_stale should return 0 for dead PID, got $rc"; rm -rf "$d"; exit 1; }

  _doctor_lock_file="$_old_lock_file"
  rm -rf "$d"

  # === Test F2 (Bug 7 fix): healing fails when installed_plugins.json is deleted ===
  # This tests that _heal_secondmate returns non-zero when installed_plugins.json is missing
  # after the git pull succeeds but before the heal verification passes.
  d=$(mktemp -d)
  origin_dir=$(mktemp -d)
  checkout_dir="$d/mkt"
  stub_dir=$(mktemp -d)
  j="$d/plugins.json"
  lock_dir="$d/lock"

  # Create origin repo with v0.1.8
  mkdir -p "$origin_dir/.claude-plugin"
  git -C "$origin_dir" init -q -b main 2>/dev/null || true
  git -C "$origin_dir" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  origin_sha_1=$(git -C "$origin_dir" rev-parse HEAD)

  # Clone origin to create marketplace checkout
  git clone -q "$origin_dir" "$checkout_dir" 2>/dev/null
  # checkout_dir now has v0.1.8 commit with sha origin_sha_1

  # Advance origin with new commit at v0.1.9
  printf '{"name":"secondmate","version":"0.1.9"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  echo "new content" >> "$origin_dir/readme.md"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.9" 2>/dev/null || true
  origin_sha_2=$(git -C "$origin_dir" rev-parse HEAD)

  # Write installed_plugins.json with a COMPLETELY DIFFERENT sha (not matching checkout_dir)
  # This creates the "stale" state: SHA differs AND version differs (0.1.8 != 0.1.9)
  mk_installed_json "$j" "deadbeef00000000000000000000000000000000" "0.1.8"

  # Create stub claude that deletes installed_plugins.json during update
  cat > "$stub_dir/claude" << 'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "$1" = "plugin" ] && [ "$2" = "update" ] && [ "$3" = "secondmate@secondmate" ] && [ "$4" = "-y" ]; then
  if [ -n "$SM_TEST_INSTALLED_JSON_FOR_STUB" ] && [ -f "$SM_TEST_INSTALLED_JSON_FOR_STUB" ]; then
    # DELETE the file (simulating corruption/failure)
    rm -f "$SM_TEST_INSTALLED_JSON_FOR_STUB"
  fi
  exit 0
else
  echo "stub claude: unexpected args: $*" >&2
  exit 1
fi
STUB_EOF
  chmod +x "$stub_dir/claude"

  # Record checkout HEAD before heal (should be origin_sha_1 - v0.1.8 commit)
  before_checkout_head=$(git -C "$checkout_dir" rev-parse HEAD)
  [ "$before_checkout_head" = "$origin_sha_1" ] || { echo "FAIL: Test F2 setup: checkout HEAD should be v0.1.8 commit"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Run REAL doctor.sh as subprocess with --heal --yes
  # Use PATH with stub claude
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" SM_TEST_INSTALLED_JSON_FOR_STUB="$j" PATH="$stub_dir:$PATH" "$script_abs" --heal --yes 2>&1)
  rc=$?

  # With Bug 7 fix: should FAIL because installed_plugins.json is missing after update
  [ "$rc" -ne 0 ] || { echo "FAIL: Test F2 bug7 fix: heal should have failed (installed_plugins.json deleted), got rc=$rc"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Assert: error message mentions installed_plugins.json
  echo "$out" | grep -q "cannot verify heal.*secondmate not found in installed_plugins.json" || { echo "FAIL: Test F2 bug7 fix: expected error about installed_plugins.json missing"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Verify file was actually deleted
  [ ! -f "$j" ] || { echo "FAIL: Test F2 bug7 fix: installed_plugins.json should have been deleted"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  rm -rf "$d" "$origin_dir" "$stub_dir"

  
  # === Test F3 (Bug 8 fix): stale state shows [!!] not [ok] and different STATUS ===
  # This tests that the table output correctly marks stale secondmate with [!!] and STATUS line differs
  d=$(mktemp -d)
  mkt_dir="$d/mkt"
  j="$d/plugins.json"

  # Create marketplace checkout with version 0.1.8
  mkdir -p "$mkt_dir/.claude-plugin"
  git -C "$mkt_dir" init -q -b main 2>/dev/null || true
  git -C "$mkt_dir" config user.email t@t.com 2>/dev/null
  git -C "$mkt_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$mkt_dir/.claude-plugin/plugin.json"
  git -C "$mkt_dir" add -A 2>/dev/null || true
  git -C "$mkt_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  old_sha=$(git -C "$mkt_dir" rev-parse HEAD)

  # Advance locally with version 0.1.9
  printf '{"name":"secondmate","version":"0.1.9"}\n' > "$mkt_dir/.claude-plugin/plugin.json"
  echo "new content" >> "$mkt_dir/readme.md"
  git -C "$mkt_dir" add -A 2>/dev/null || true
  git -C "$mkt_dir" commit -q -m "v0.1.9" 2>/dev/null || true

  # installed_plugins.json has the old sha/version (creates stale state)
  mk_installed_json "$j" "$old_sha" "0.1.8"

  # Run doctor.sh --report and capture output
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$mkt_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" "$script_abs" --report 2>&1)

  # With Bug 8 fix: secondmate row should have [!!] (not [ok])
  # Find the secondmate row and check its status marker
  secondmate_row=$(echo "$out" | grep "secondmate plugin" || true)
  echo "$secondmate_row" | grep -q "\[!!\]" || { echo "FAIL: Test F3 bug8 fix: secondmate stale row should have [!!], got: $secondmate_row"; echo "full output:"; echo "$out" >&2; rm -rf "$d"; exit 1; }

  # Assert: STATUS line differs from plain "ready (core plus checker harness present)"
  status_line=$(echo "$out" | grep "^STATUS:" || true)
  [ -n "$status_line" ] || { echo "FAIL: Test F3 bug8 fix: STATUS line not found"; echo "full output:"; echo "$out" >&2; rm -rf "$d"; exit 1; }
  echo "$status_line" | grep -q "ready, but secondmate plugin needs healing" || { echo "FAIL: Test F3 bug8 fix: STATUS should mention healing needed, got: $status_line"; rm -rf "$d"; exit 1; }
  # Make sure it's NOT the plain ready status
  echo "$status_line" | grep -q "ready (core plus checker harness present)" && { echo "FAIL: Test F3 bug8 fix: STATUS should NOT be plain ready, got: $status_line"; rm -rf "$d"; exit 1; }

  rm -rf "$d"

  # === Test G: malformed installed_plugins.json (Bug 9 fix) ===
  # Test that UNKNOWN status is properly tracked, reported, and heals fail with non-zero exit
  d=$(mktemp -d)
  mkt_dir="$d/mkt"
  j="$d/plugins.json"
  lock_dir="$d/lock"

  # Create marketplace checkout with version 0.1.8
  mkdir -p "$mkt_dir/.claude-plugin"
  git -C "$mkt_dir" init -q -b main 2>/dev/null || true
  git -C "$mkt_dir" config user.email t@t.com 2>/dev/null
  git -C "$mkt_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$mkt_dir/.claude-plugin/plugin.json"
  git -C "$mkt_dir" add -A 2>/dev/null || true
  git -C "$mkt_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  sha=$(git -C "$mkt_dir" rev-parse HEAD)

  # Create malformed installed_plugins.json (invalid JSON)
  echo '{not-json' > "$j"

  # --- Test G1: --report should show [!!] for secondmate and NOT plain "ready" STATUS ---
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$mkt_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" "$script_abs" --report 2>&1)

  # secondmate row should still show [!!] (Bug 8 generalization already handles this)
  secondmate_row=$(echo "$out" | grep "secondmate plugin" || true)
  echo "$secondmate_row" | grep -q "\[!!\]" || { echo "FAIL: Test G1 bug9 fix: secondmate unknown row should have [!!], got: $secondmate_row"; echo "full output:"; echo "$out" >&2; rm -rf "$d"; exit 1; }

  # STATUS line should NOT be plain "ready (core plus checker harness present)"
  status_line=$(echo "$out" | grep "^STATUS:" || true)
  [ -n "$status_line" ] || { echo "FAIL: Test G1 bug9 fix: STATUS line not found"; echo "full output:"; echo "$out" >&2; rm -rf "$d"; exit 1; }
  echo "$status_line" | grep -q "ready, but secondmate plugin state is unknown" || { echo "FAIL: Test G1 bug9 fix: STATUS should mention unknown state, got: $status_line"; rm -rf "$d"; exit 1; }
  echo "$status_line" | grep -q "ready (core plus checker harness present)" && { echo "FAIL: Test G1 bug9 fix: STATUS should NOT be plain ready, got: $status_line"; rm -rf "$d"; exit 1; }

  # --- Test G2: --heal --yes should exit non-zero when installed_plugins.json is malformed ---
  # Create a valid installed_plugins.json first, then make it malformed to simulate failure
  mk_installed_json "$j" "$sha" "0.1.8"
  # Now make it malformed
  echo '{not-json' > "$j"

  # Run REAL doctor.sh as subprocess with --heal --yes
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$mkt_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" "$script_abs" --heal --yes 2>&1)
  heal_rc=$?

  # Should fail with non-zero exit code
  [ "$heal_rc" -ne 0 ] || { echo "FAIL: Test G2 bug9 fix: heal should have failed (malformed installed_plugins.json), got rc=$heal_rc"; echo "output: $out" >&2; rm -rf "$d"; exit 1; }

  # Should print appropriate error message
  echo "$out" | grep -q "cannot determine secondmate plugin state" || { echo "FAIL: Test G2 bug9 fix: expected error about unknown state, got: $out"; rm -rf "$d"; exit 1; }
  echo "$out" | grep -q "installed_plugins.json is malformed" || { echo "FAIL: Test G2 bug9 fix: expected error about malformed installed_plugins.json, got: $out"; rm -rf "$d"; exit 1; }

  rm -rf "$d"

  # === Test H (Bug 10 fix): missing marketplace checkout triggers hard-abort in heal ===
  # This verifies that when the marketplace checkout doesn't exist at all,
  # a real doctor.sh --heal --yes subprocess invocation exits non-zero
  # and prints a [FAIL] message (not silently succeeds with "STATUS: ready")
  d=$(mktemp -d)
  origin_dir=$(mktemp -d)
  j="$d/plugins.json"
  lock_dir="$d/lock"

  # Create origin repo with v0.1.8
  mkdir -p "$origin_dir/.claude-plugin"
  git -C "$origin_dir" init -q -b main 2>/dev/null || true
  git -C "$origin_dir" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  origin_sha_1=$(git -C "$origin_dir" rev-parse HEAD)

  # Create valid installed_plugins.json pointing to existing checkout
  mk_installed_json "$j" "$origin_sha_1" "0.1.8"

  # Create the marketplace checkout (so state is 'ok' initially)
  checkout_dir="$d/mkt"
  git clone -q "$origin_dir" "$checkout_dir" 2>/dev/null

  # Advance origin with new commit at v0.1.9
  printf '{"name":"secondmate","version":"0.1.9"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  echo "new content" >> "$origin_dir/readme.md"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.9" 2>/dev/null || true
  origin_sha_2=$(git -C "$origin_dir" rev-parse HEAD)

  # Rewrite installed_plugins.json with OLD sha (creates stale state, needs heal)
  mk_installed_json "$j" "deadbeef00000000000000000000000000000000" "0.1.8"

  # Run REAL doctor.sh with --heal --yes and a NONEXISTENT marketplace path
  # This should trigger the 'missing' state and fail (Bug 10 fix)
  nonexistent_mkt="$d/i_dont_exist"
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$nonexistent_mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" "$script_abs" --heal --yes 2>&1)
  rc=$?

  # With Bug 10 fix: should fail with non-zero exit code
  # (Before the fix: would exit 0 and print "STATUS: ready" - silent no-op)
  [ "$rc" -ne 0 ] || { echo "FAIL: Test H bug10 fix: heal should have failed (missing marketplace checkout), got rc=$rc"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir"; exit 1; }

  # Assert: error message mentions missing checkout
  echo "$out" | grep -q "\[FAIL\] secondmate marketplace checkout not found" || { echo "FAIL: Test H bug10 fix: expected [FAIL] about missing checkout, got: $out"; rm -rf "$d" "$origin_dir"; exit 1; }

  # Assert: error message includes the fix command
  echo "$out" | grep -q "claude plugin marketplace add eshwarvijay/secondmate" || { echo "FAIL: Test H bug10 fix: expected fix command in output, got: $out"; rm -rf "$d" "$origin_dir"; exit 1; }

  rm -rf "$d" "$origin_dir"

  # === Test I (Bug 11 fix): atomic lock steal via mv ===
  # This tests the atomic rename fix by calling the REAL _acquire_heal_lock function
  # with a stubbed 'mv' command that fails on first invocation, simulating the race
  # condition where another process already claimed the lock.
  # We verify that _acquire_heal_lock properly handles the mv failure (back off and retry)
  # and that the mv command is actually called (the Bug 11 fix).
  # Note: We use an arbitrary large PID (999999) that's extremely unlikely to be alive.
  d=$(mktemp -d)
  lock_dir="$d/lock"
  lock_file="$lock_dir/secondmate-heal.lock"
  
  # Create a temp directory for the mv stub
  stub_dir=$(mktemp -d)
  stub_mv="$stub_dir/mv"
  marker_file="$d/mv_called"
  
  # Create stub mv that: on first call, fails after removing source (simulating race);
  # on subsequent calls, delegates to real mv
  # Uses environment variables: STUB_MV_MARKER (marker file), STUB_MV_SOURCE (source to remove)
  cat > "$stub_mv" << 'EOF'
#!/bin/bash
# stub mv: first call fails after removing source (simulating race), subsequent calls succeed
if [ ! -f "${STUB_MV_MARKER:-}" ]; then
  # First invocation - record it and simulate race by removing source
  touch "${STUB_MV_MARKER:-}"
  rm -rf "${STUB_MV_SOURCE:-}" 2>/dev/null
  exit 1
else
  # Subsequent Invocation - delegate to real mv
  /bin/mv "$@"
fi
EOF
  chmod +x "$stub_mv"
  
  # Create a lock with a stale timestamp (using a DEAD PID for testing)
  mkdir -p "$lock_file"
  old_ts=$(( $(date +%s) - 60 ))  # 60 seconds ago
  dead_pid=999999  # Arbitrary large PID that's not alive
  echo "$old_ts" > "$lock_file/.timestamp"
  echo "$dead_pid" > "$lock_file/.pid"
  
  _old_lock_dir="$_doctor_lock_dir"
  _old_lock_file="$_doctor_lock_file"
  _doctor_lock_dir="$lock_dir"
  _doctor_lock_file="$lock_file"
  
  # Call _acquire_heal_lock with stubbed mv on PATH
  # The stub will fail on first call (simulating race), then subsequent calls succeed
  # Export marker and source path for stub to use
  export STUB_MV_MARKER="$marker_file"
  export STUB_MV_SOURCE="$lock_file"
  PATH="$stub_dir:$PATH" _acquire_heal_lock >/dev/null 2>&1
  rc=$?
  
  # Clean up environment variables
  unset STUB_MV_MARKER
  unset STUB_MV_SOURCE
  
  # Verify mv was called (marker file exists)
  [ -f "$marker_file" ] || { echo "FAIL: Test I bug11 fix: mv should have been called (no marker)"; _doctor_lock_dir="$_old_lock_dir"; _doctor_lock_file="$_old_lock_file"; rm -rf "$d" "$stub_dir"; exit 1; }
  
  # Verify lock was acquired successfully
  [ "$rc" -eq 0 ] || { echo "FAIL: Test I bug11 fix: _acquire_heal_lock should succeed, got rc=$rc"; _doctor_lock_dir="$_old_lock_dir"; _doctor_lock_file="$_old_lock_file"; rm -rf "$d" "$stub_dir"; exit 1; }
  
  # Verify new lock was created (fresh, not the old stale one)
  [ -d "$lock_file" ] || { echo "FAIL: Test I bug11 fix: lock directory doesn't exist after successful acquire"; _doctor_lock_dir="$_old_lock_dir"; _doctor_lock_file="$_old_lock_file"; rm -rf "$d" "$stub_dir"; exit 1; }
  
  # Verify fresh timestamp (not the old stale one)
  new_ts=$(cat "$lock_file/.timestamp" 2>/dev/null || echo "")
  [ -n "$new_ts" ] || { echo "FAIL: Test I bug11 fix: couldn't read timestamp after acquire"; _doctor_lock_dir="$_old_lock_dir"; _doctor_lock_file="$_old_lock_file"; rm -rf "$d" "$stub_dir"; exit 1; }
  [ "$new_ts" -gt "$old_ts" ] || { echo "FAIL: Test I bug11 fix: timestamp wasn't updated"; _doctor_lock_dir="$_old_lock_dir"; _doctor_lock_file="$_old_lock_file"; rm -rf "$d" "$stub_dir"; exit 1; }
  
  _doctor_lock_dir="$_old_lock_dir"
  _doctor_lock_file="$_old_lock_file"
  rm -rf "$d" "$stub_dir"

  # === Test I2 (Bug 11 companion): normal stale-lock steal works end-to-end ===
  # This confirms the normal path (no race) still works: a genuinely stale lock
  # gets stolen and replaced with a fresh one.
  # Note: We use an arbitrary large PID (999999) that's extremely unlikely to be alive.
  d=$(mktemp -d)
  lock_dir="$d/lock"
  lock_file="$lock_dir/secondmate-heal.lock"
  
  # Create a lock with a STALE timestamp (older than max_wait=30 seconds) and DEAD PID
  mkdir -p "$lock_file"
  old_ts=$(( $(date +%s) - 60 ))  # 60 seconds ago
  dead_pid=999999  # Arbitrary large PID that's not alive
  echo "$old_ts" > "$lock_file/.timestamp"
  echo "$dead_pid" > "$lock_file/.pid"
  
  _old_lock_dir="$_doctor_lock_dir"
  _old_lock_file="$_doctor_lock_file"
  _doctor_lock_dir="$lock_dir"
  _doctor_lock_file="$lock_file"
  
  # Run the full _acquire_heal_lock logic - with the Bug 11 fix, it should:
  # 1. Detect stale lock via _is_lock_still_stale
  # 2. Atomically mv it to a unique name
  # 3. Verify it's still the same stale lock (by checking moved copy's metadata)
  # 4. Remove the moved copy
  # 5. Create fresh lock
  # 6. Return 0
  
  out=$(_acquire_heal_lock 2>&1)
  rc=$?
  
  # Should succeed (return 0)
  [ "$rc" -eq 0 ] || { echo "FAIL: Test I2 bug11 fix: _acquire_heal_lock should succeed for stale lock, got rc=$rc"; echo "output: $out" >&2; _doctor_lock_dir="$_old_lock_dir"; _doctor_lock_file="$_old_lock_file"; rm -rf "$d"; exit 1; }
  
  # Verify new lock was created
  [ -d "$lock_file" ] || { echo "FAIL: Test I2 bug11 fix: lock directory doesn't exist after successful acquire"; _doctor_lock_dir="$_old_lock_dir"; _doctor_lock_file="$_old_lock_file"; rm -rf "$d"; exit 1; }
  
  # Verify fresh timestamp (not the old stale one)
  new_ts=$(cat "$lock_file/.timestamp" 2>/dev/null || echo "")
  [ -n "$new_ts" ] || { echo "FAIL: Test I2 bug11 fix: couldn't read timestamp after acquire"; _doctor_lock_dir="$_old_lock_dir"; _doctor_lock_file="$_old_lock_file"; rm -rf "$d"; exit 1; }
  [ "$new_ts" -gt "$old_ts" ] || { echo "FAIL: Test I2 bug11 fix: timestamp wasn't updated"; _doctor_lock_dir="$_old_lock_dir"; _doctor_lock_file="$_old_lock_file"; rm -rf "$d"; exit 1; }
  
  _doctor_lock_dir="$_old_lock_dir"
  _doctor_lock_file="$_old_lock_file"
  rm -rf "$d"

  # === Test J (Bug 12 fix): missing marketplace checkout triggers hard-abort in heal ===
  # This tests that when the marketplace checkout doesn't exist at all,
  # a real doctor.sh --heal --yes subprocess invocation exits non-zero
  # and prints a [FAIL] message (not silently succeeds with "STATUS: ready")
  # Also verifies the STATUS line in report output is NOT "ready (core plus checker harness present)"
  d=$(mktemp -d)
  origin_dir=$(mktemp -d)
  j="$d/plugins.json"
  lock_dir="$d/lock"

  # Create origin repo with v0.1.8
  mkdir -p "$origin_dir/.claude-plugin"
  git -C "$origin_dir" init -q -b main 2>/dev/null || true
  git -C "$origin_dir" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  origin_sha_1=$(git -C "$origin_dir" rev-parse HEAD)

  # Create a valid installed_plugins.json pointing to existing checkout
  mk_installed_json "$j" "$origin_sha_1" "0.1.8"

  # Create the marketplace checkout (so state is 'ok' initially)
  checkout_dir="$d/mkt"
  git clone -q "$origin_dir" "$checkout_dir" 2>/dev/null

  # Advance origin with new commit at v0.1.9
  printf '{"name":"secondmate","version":"0.1.9"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  echo "new content" >> "$origin_dir/readme.md"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.9" 2>/dev/null || true
  origin_sha_2=$(git -C "$origin_dir" rev-parse HEAD)

  # Rewrite installed_plugins.json with OLD sha (creates stale state, needs heal)
  mk_installed_json "$j" "deadbeef00000000000000000000000000000000" "0.1.8"

  # First run: marketplace exists (heal should attempt and fail due to missing remote)
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" "$script_abs" --report 2>&1)
  # Assert: STATUS line should NOT be plain ready (since there's a stale state)
  status_line=$(echo "$out" | grep "^STATUS:" || true)
  [ -n "$status_line" ] || { echo "FAIL: Test J (setup) STATUS line not found"; rm -rf "$d" "$origin_dir"; exit 1; }
  echo "$status_line" | grep -q "ready (core plus checker harness present)" && { echo "FAIL: Test J (setup) STATUS should NOT be plain ready due to stale state"; rm -rf "$d" "$origin_dir"; exit 1; }

  # Second run: marketplace checkout missing (missing state)
  nonexistent_mkt="$d/i_dont_exist"
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$nonexistent_mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" "$script_abs" --report 2>&1)

  # Assert: secondmate row exists and shows [!!]
  secondmate_row=$(echo "$out" | grep "secondmate plugin" || true)
  echo "$secondmate_row" | grep -q "\[!!\]" || { echo "FAIL: Test J bug12 fix: secondmate missing row should have [!!], got: $secondmate_row"; rm -rf "$d" "$origin_dir"; exit 1; }

  # Assert: STATUS line is NOT plain ready (Bug 12 fix)
  status_line=$(echo "$out" | grep "^STATUS:" || true)
  [ -n "$status_line" ] || { echo "FAIL: Test J bug12 fix: STATUS line not found"; rm -rf "$d" "$origin_dir"; exit 1; }
  echo "$status_line" | grep -q "ready (core plus checker harness present)" && { echo "FAIL: Test J bug12 fix: STATUS should NOT be plain ready when marketplace missing, got: $status_line"; rm -rf "$d" "$origin_dir"; exit 1; }
  echo "$status_line" | grep -q "secondmate plugin marketplace checkout is missing" || { echo "FAIL: Test J bug12 fix: STATUS should mention missing marketplace, got: $status_line"; rm -rf "$d" "$origin_dir"; exit 1; }

  # Third run: --heal --yes with missing marketplace should exit non-zero
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$nonexistent_mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" "$script_abs" --heal --yes 2>&1)
  rc=$?

  # Should fail with non-zero exit code (Bug 10 fix, which is prerequisite for Bug 12)
  [ "$rc" -ne 0 ] || { echo "FAIL: Test J bug12 fix: heal should have failed (missing marketplace checkout), got rc=$rc"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir"; exit 1; }

  # Assert: error message mentions missing checkout
  echo "$out" | grep -q "\[FAIL\] secondmate marketplace checkout not found" || { echo "FAIL: Test J bug12 fix: expected [FAIL] about missing checkout, got: $out"; rm -rf "$d" "$origin_dir"; exit 1; }

  rm -rf "$d" "$origin_dir"

  # === Test K (git fetch failure): _heal_secondmate hard-aborts when origin is unreachable ===
  d=$(mktemp -d)
  mkt_dir="$d/mkt"
  j="$d/plugins.json"
  lock_dir="$d/lock"

  mkdir -p "$mkt_dir/.claude-plugin"
  git -C "$mkt_dir" init -q -b main 2>/dev/null || true
  git -C "$mkt_dir" config user.email t@t.com 2>/dev/null
  git -C "$mkt_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$mkt_dir/.claude-plugin/plugin.json"
  git -C "$mkt_dir" add -A 2>/dev/null || true
  git -C "$mkt_dir" commit -q -m "v0.1.8" 2>/dev/null || true

  # Clean checkout (passes dirty-tree/detached-HEAD checks) with an unreachable origin remote,
  # so the failure specifically comes from the git fetch step.
  git -C "$mkt_dir" remote add origin "$d/does-not-exist-xyz" 2>/dev/null || true

  mk_installed_json "$j" "deadbeef00000000000000000000000000000000" "0.1.7"

  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$mkt_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" "$script_abs" --heal --yes 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || { echo "FAIL: Test K fetch-failure: heal should have failed (unreachable origin), got rc=$rc"; echo "output: $out" >&2; rm -rf "$d"; exit 1; }
  echo "$out" | grep -q "\[FAIL\] git fetch failed" || { echo "FAIL: Test K fetch-failure: expected [FAIL] git fetch failed, got: $out"; rm -rf "$d"; exit 1; }

  rm -rf "$d"

  # === Test L (claude plugin update failure): _heal_secondmate hard-aborts when the CLI fails ===
  d=$(mktemp -d)
  origin_dir=$(mktemp -d)
  checkout_dir="$d/mkt"
  stub_dir=$(mktemp -d)
  j="$d/plugins.json"
  lock_dir="$d/lock"

  mkdir -p "$origin_dir/.claude-plugin"
  git -C "$origin_dir" init -q -b main 2>/dev/null || true
  git -C "$origin_dir" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.8" 2>/dev/null || true

  git clone -q "$origin_dir" "$checkout_dir" 2>/dev/null

  printf '{"name":"secondmate","version":"0.1.9"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.9" 2>/dev/null || true

  mk_installed_json "$j" "deadbeef00000000000000000000000000000000" "0.1.8"

  cat > "$stub_dir/claude" << 'STUB_EOF'
#!/usr/bin/env bash
echo "stub claude: simulating plugin update failure" >&2
exit 1
STUB_EOF
  chmod +x "$stub_dir/claude"

  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" PATH="$stub_dir:$PATH" "$script_abs" --heal --yes 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || { echo "FAIL: Test L update-failure: heal should have failed (claude plugin update failed), got rc=$rc"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }
  echo "$out" | grep -q "\[FAIL\] claude plugin update failed" || { echo "FAIL: Test L update-failure: expected [FAIL] claude plugin update failed, got: $out"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  rm -rf "$d" "$origin_dir" "$stub_dir"

  # === Test M (bug fix verification): --heal updates table to show [ok] in same invocation ===
  # This test reproduces the exact bug scenario:
  # - marketplace checkout is genuinely stale (origin has newer SHA + version bump)
  # - installed_plugins.json has old sha/version
  # - doctor.sh --heal --yes runs heal (pull + update) successfully
  # - the SAME invocation's trailing table must show [ok], NOT [!!]/stale
  d=$(mktemp -d)
  origin_dir=$(mktemp -d)
  checkout_dir="$d/mkt"
  stub_dir=$(mktemp -d)
  j="$d/plugins.json"
  lock_dir="$d/lock"

  # Create origin repo with first commit (version 0.1.8)
  mkdir -p "$origin_dir/.claude-plugin"
  git -C "$origin_dir" init -q -b main 2>/dev/null || true
  git -C "$origin_dir" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  origin_sha_1=$(git -C "$origin_dir" rev-parse HEAD)

  # Clone origin to create marketplace checkout
  git clone -q "$origin_dir" "$checkout_dir" 2>/dev/null

  # Advance origin with second commit (version 0.1.9) - REAL VERSION BUMP
  printf '{"name":"secondmate","version":"0.1.9"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.9" 2>/dev/null || true
  origin_sha_2=$(git -C "$origin_dir" rev-parse HEAD)

  # Update marketplace checkout to match origin's new commit
  git -C "$checkout_dir" fetch origin 2>/dev/null
  git -C "$checkout_dir" fetch origin 2>/dev/null && git -C "$checkout_dir" reset --hard origin/main 2>/dev/null || true

  # Write installed_plugins.json with OLD sha and version (creates genuinely stale state)
  # Use origin_sha_1 (the OLD commit that checkout had before we advanced)
  mk_installed_json "$j" "$origin_sha_1" "0.1.8"

  # Verify setup: running doctor.sh --report BEFORE heal should show [!!] stale
  before_out=$(SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" "$script_abs" --report 2>&1)
  before_row=$(echo "$before_out" | grep "secondmate plugin" || true)
  echo "$before_row" | grep -q "\[!!\]" || { echo "FAIL: Test M setup: before-heal stale row should have [!!], got: $before_row"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }
  echo "$before_row" | grep -q "stale" || { echo "FAIL: Test M setup: before-heal should show stale, got: $before_row"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Create stub claude that properly updates installed_plugins.json with new sha/version
  cat > "$stub_dir/claude" << 'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "$1" = "plugin" ] && [ "$2" = "update" ] && [ "$3" = "secondmate@secondmate" ] && [ "$4" = "-y" ]; then
  if [ -n "$SM_TEST_INSTALLED_JSON_FOR_STUB" ] && [ -f "$SM_TEST_INSTALLED_JSON_FOR_STUB" ]; then
    # Get new sha and version from origin repo
    origin_sha=$(git -C "$SM_SECONDMATE_MARKETPLACE_DIR" rev-parse HEAD 2>/dev/null || true)
    origin_ver=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('version',''))" "$SM_SECONDMATE_MARKETPLACE_DIR/.claude-plugin/plugin.json" 2>/dev/null || true)
    python3 -c "
import json,sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    plugins = data.get('plugins', {})
    if isinstance(plugins, dict):
        for key in list(plugins.keys()):
            if key.startswith('secondmate@'):
                entries = plugins[key]
                if isinstance(entries, list) and len(entries) > 0 and isinstance(entries[0], dict):
                    entries[0]['gitCommitSha'] = '$origin_sha'
                    entries[0]['version'] = '$origin_ver'
    with open(sys.argv[1], 'w') as f:
        json.dump(data, f)
except Exception as e:
    import sys
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" "$SM_TEST_INSTALLED_JSON_FOR_STUB"
  fi
  exit 0
else
  echo "stub claude: unexpected args: $*" >&2
  exit 1
fi
STUB_EOF
  chmod +x "$stub_dir/claude"

  # Record checkout HEAD before heal
  before_checkout_head=$(git -C "$checkout_dir" rev-parse HEAD)

  # Run REAL doctor.sh with --heal --yes
  # CRITICAL: we capture the FULL output including trailing table
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" SM_TEST_INSTALLED_JSON_FOR_STUB="$j" PATH="$stub_dir:$PATH" "$script_abs" --heal --yes 2>&1)
  heal_rc=$?

  # Assert: heal succeeded
  [ "$heal_rc" -eq 0 ] || { echo "FAIL: Test M heal test expected rc=0, got $heal_rc"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Assert: checkout HEAD advanced (proving real git pull happened)
  after_checkout_head=$(git -C "$checkout_dir" rev-parse HEAD)
  [ "$after_checkout_head" = "$origin_sha_2" ] || { echo "FAIL: Test M: checkout HEAD $after_checkout_head != origin HEAD $origin_sha_2"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Assert: installed_plugins.json shows new sha/version (proving stub claude was invoked)
  after_sha=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); p=d.get('plugins',{}); [print(e.get('gitCommitSha','')) for k,v in p.items() if isinstance(v,list) for e in v if isinstance(e,dict) and k.startswith('secondmate@')]" "$j" 2>/dev/null)
  after_ver=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); p=d.get('plugins',{}); [print(e.get('version','')) for k,v in p.items() if isinstance(v,list) for e in v if isinstance(e,dict) and k.startswith('secondmate@')]" "$j" 2>/dev/null)
  [ "$after_sha" = "$origin_sha_2" ] || { echo "FAIL: Test M: installed_plugins.json sha $after_sha != expected $origin_sha_2"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }
  [ "$after_ver" = "0.1.9" ] || { echo "FAIL: Test M: installed_plugins.json version $after_ver != expected 0.1.9"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # CRITICAL: Check the SAME invocation's trailing table output
  # The table must show NOT-[!!] for secondmate plugin (either [ok] or some other [!!] for a different reason like reload_pending)
  # Specifically, it must NOT show [!!] with "stale" in the row (which was the bug - stale showing even after heal)
  echo "$out" | grep -A 50 "secondmate doctor" | grep "secondmate plugin" > /dev/null || { echo "FAIL: Test M: could not find secondmate row in table output"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # The actual test: secondmate row in the trailing table must NOT be marked as (stale)
  # After heal, it could be (stale) if heal failed, OR (reload_pending) if heal succeeded but /reload-plugins not run
  # OR [ok] if everything matches. But it must NOT be (stale) if heal succeeded.
  table_output=$(echo "$out" | grep -A 50 "secondmate doctor" | grep "secondmate plugin" || true)
  echo "$table_output" | grep -q "(stale)" && { echo "FAIL: Test M bug fix: trailing table must NOT show (stale) for secondmate plugin after successful heal, got: $table_output"; echo "full output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }
  # Either [ok] or [!!] with something other than stale is acceptable
  # (reload_pending is [!!] because it needs /reload-plugins but heal did succeed)
  # So just verify it's not stale
  true

  rm -rf "$d" "$origin_dir" "$stub_dir"

  # === Test N (bug fix verification, interactive path): --heal without --yes also updates table ===
  # This is the EXACT SAME setup as Test M, but uses the interactive path (no --yes flag)
  # instead pipes 'y' to confirm the heal. This verifies the fix works for BOTH branches.
  d=$(mktemp -d)
  origin_dir=$(mktemp -d)
  checkout_dir="$d/mkt"
  stub_dir=$(mktemp -d)
  j="$d/plugins.json"
  lock_dir="$d/lock"

  # Create origin repo with first commit (version 0.1.8)
  mkdir -p "$origin_dir/.claude-plugin"
  git -C "$origin_dir" init -q -b main 2>/dev/null || true
  git -C "$origin_dir" config user.email t@t.com 2>/dev/null
  git -C "$origin_dir" config user.name t 2>/dev/null
  printf '{"name":"secondmate","version":"0.1.8"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.8" 2>/dev/null || true
  origin_sha_1=$(git -C "$origin_dir" rev-parse HEAD)

  # Clone origin to create marketplace checkout
  git clone -q "$origin_dir" "$checkout_dir" 2>/dev/null

  # Advance origin with second commit (version 0.1.9) - REAL VERSION BUMP
  printf '{"name":"secondmate","version":"0.1.9"}\n' > "$origin_dir/.claude-plugin/plugin.json"
  git -C "$origin_dir" add -A 2>/dev/null || true
  git -C "$origin_dir" commit -q -m "v0.1.9" 2>/dev/null || true
  origin_sha_2=$(git -C "$origin_dir" rev-parse HEAD)

  # Update marketplace checkout to match origin's new commit
  git -C "$checkout_dir" fetch origin 2>/dev/null
  git -C "$checkout_dir" fetch origin 2>/dev/null && git -C "$checkout_dir" reset --hard origin/main 2>/dev/null || true

  # Write installed_plugins.json with OLD sha and version (creates genuinely stale state)
  # Use origin_sha_1 (the OLD commit that checkout had before we advanced)
  mk_installed_json "$j" "$origin_sha_1" "0.1.8"

  # Verify setup: running doctor.sh --report BEFORE heal should show [!!] stale
  before_out=$(SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" "$script_abs" --report 2>&1)
  before_row=$(echo "$before_out" | grep "secondmate plugin" || true)
  echo "$before_row" | grep -q "\[!!\]" || { echo "FAIL: Test N setup: before-heal stale row should have [!!], got: $before_row"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }
  echo "$before_row" | grep -q "stale" || { echo "FAIL: Test N setup: before-heal should show stale, got: $before_row"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Create stub claude that properly updates installed_plugins.json with new sha/version
  cat > "$stub_dir/claude" << 'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
# Handle both: interactive (3 args) and --yes mode (4 args with -y)
if [ "$1" = "plugin" ] && [ "$2" = "update" ] && [ "$3" = "secondmate@secondmate" ]; then
  if [ -n "$SM_TEST_INSTALLED_JSON_FOR_STUB" ] && [ -f "$SM_TEST_INSTALLED_JSON_FOR_STUB" ]; then
    # Get new sha and version from origin repo
    origin_sha=$(git -C "$SM_SECONDMATE_MARKETPLACE_DIR" rev-parse HEAD 2>/dev/null || true)
    origin_ver=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('version',''))" "$SM_SECONDMATE_MARKETPLACE_DIR/.claude-plugin/plugin.json" 2>/dev/null || true)
    python3 -c "
import json,sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    plugins = data.get('plugins', {})
    if isinstance(plugins, dict):
        for key in list(plugins.keys()):
            if key.startswith('secondmate@'):
                entries = plugins[key]
                if isinstance(entries, list) and len(entries) > 0 and isinstance(entries[0], dict):
                    entries[0]['gitCommitSha'] = '$origin_sha'
                    entries[0]['version'] = '$origin_ver'
    with open(sys.argv[1], 'w') as f:
        json.dump(data, f)
except Exception as e:
    import sys
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" "$SM_TEST_INSTALLED_JSON_FOR_STUB"
  fi
  exit 0
else
  echo "stub claude: unexpected args: $*" >&2
  exit 1
fi
STUB_EOF
  chmod +x "$stub_dir/claude"

  # Record checkout HEAD before heal
  before_checkout_head=$(git -C "$checkout_dir" rev-parse HEAD)

  # Run REAL doctor.sh with --heal (NO --yes - uses interactive path)
  # Pipe 'y' to confirm the heal
  out=$(echo y | SM_SECONDMATE_MARKETPLACE_DIR="$checkout_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" SM_TEST_INSTALLED_JSON_FOR_STUB="$j" PATH="$stub_dir:$PATH" "$script_abs" --heal 2>&1)
  heal_rc=$?

  # Assert: heal succeeded
  [ "$heal_rc" -eq 0 ] || { echo "FAIL: Test N heal test expected rc=0, got $heal_rc"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Assert: checkout HEAD advanced (proving real git pull happened)
  after_checkout_head=$(git -C "$checkout_dir" rev-parse HEAD)
  [ "$after_checkout_head" = "$origin_sha_2" ] || { echo "FAIL: Test N: checkout HEAD $after_checkout_head != origin HEAD $origin_sha_2"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # Assert: installed_plugins.json shows new sha/version (proving stub claude was invoked)
  after_sha=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); p=d.get('plugins',{}); [print(e.get('gitCommitSha','')) for k,v in p.items() if isinstance(v,list) for e in v if isinstance(e,dict) and k.startswith('secondmate@')]" "$j" 2>/dev/null)
  after_ver=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); p=d.get('plugins',{}); [print(e.get('version','')) for k,v in p.items() if isinstance(v,list) for e in v if isinstance(e,dict) and k.startswith('secondmate@')]" "$j" 2>/dev/null)
  [ "$after_sha" = "$origin_sha_2" ] || { echo "FAIL: Test N: installed_plugins.json sha $after_sha != expected $origin_sha_2"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }
  [ "$after_ver" = "0.1.9" ] || { echo "FAIL: Test N: installed_plugins.json version $after_ver != expected 0.1.9"; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # CRITICAL: Check the SAME invocation's trailing table output
  # The table must show NOT-[!!] for secondmate plugin (either [ok] or some other [!!] for a different reason like reload_pending)
  # Specifically, it must NOT show [!!] with "stale" in the row (which was the bug - stale showing even after heal)
  echo "$out" | grep -A 50 "secondmate doctor" | grep "secondmate plugin" > /dev/null || { echo "FAIL: Test N: could not find secondmate row in table output"; echo "output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  # The actual test: secondmate row in the trailing table must NOT be marked as (stale)
  # After heal, it could be (stale) if heal failed, OR (reload_pending) if heal succeeded but /reload-plugins not run
  # OR [ok] if everything matches. But it must NOT be (stale) if heal succeeded.
  table_output=$(echo "$out" | grep -A 50 "secondmate doctor" | grep "secondmate plugin" || true)
  echo "$table_output" | grep -q "(stale)" && { echo "FAIL: Test N bug fix: trailing table must NOT show (stale) for secondmate plugin after successful heal, got: $table_output"; echo "full output: $out" >&2; rm -rf "$d" "$origin_dir" "$stub_dir"; exit 1; }

  rm -rf "$d" "$origin_dir" "$stub_dir"

  # === Test O (reload_pending state): STATUS line distinguishes reload_pending from stale ===
  # This tests that a genuinely reload_pending state (SHA matches, version differs,
  # heal already happened on disk but /reload-plugins not yet run) produces a
  # different STATUS message than a stale state (needs healing).
  # The row output for reload_pending already shows [!!] with the correct fix command.
  # This test verifies the bottom STATUS line now mentions "session reload" and "reload-plugins",
  # NOT "needs healing" (which is what stale/silent_drift share).
  d=$(mktemp -d)
  mkt_dir="$d/mkt"
  j="$d/plugins.json"
  lock_dir="$d/lock"

  # Build reload_pending fixture: use exact shape of existing Test 4 fixture
  # - SHA in marketplace matches installed_sha in installed_plugins.json
  # - But running_version (from this worktree's plugin.json) differs from installed_version
  mkdir -p "$mkt_dir/.claude-plugin"
  git -C "$mkt_dir" init -q -b main 2>/dev/null || true
  git -C "$mkt_dir" config user.email t@t.com 2>/dev/null
  git -C "$mkt_dir" config user.name t 2>/dev/null
  # marketplace has the CURRENT version_line (this worktree)
  printf '{"name":"secondmate","version":"%s"}\n' "$version_line" > "$mkt_dir/.claude-plugin/plugin.json"
  git -C "$mkt_dir" add -A 2>/dev/null || true
  git -C "$mkt_dir" commit -q -m "v$version_line" 2>/dev/null || true
  sha=$(git -C "$mkt_dir" rev-parse HEAD)

  # installed_plugins.json has the SAME SHA but OLD version (e.g. "0.1.0-old")
  # This guarantees installed_version differs from running_version, creating reload_pending
  mk_installed_json "$j" "$sha" "${version_line}-old"

  # Run doctor.sh --report (NOT --json) to get table output with STATUS line
  out=$(SM_SECONDMATE_MARKETPLACE_DIR="$mkt_dir" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$lock_dir" "$script_abs" --report 2>&1)

  # The secondmate row must still show [!!] (already-correct behavior from Test 4)
  secondmate_row=$(echo "$out" | grep "secondmate plugin (reload pending)" || true)
  echo "$secondmate_row" | grep -q "\[!!\]" || { echo "FAIL: Test O reload_pending row should have [!!], got: $secondmate_row"; echo "full output:"; echo "$out" >&2; rm -rf "$d"; exit 1; }

  # The fix command must still show /reload-plugins (already-correct behavior from Test 4)
  echo "$secondmate_row" | grep -q "reload-plugins" || { echo "FAIL: Test O reload_pending row fix command should mention reload-plugins, got: $secondmate_row"; echo "full output:"; echo "$out" >&2; rm -rf "$d"; exit 1; }

  # The STATUS line must mention a session reload
  status_line=$(echo "$out" | grep "^STATUS:" || true)
  [ -n "$status_line" ] || { echo "FAIL: Test O reload_pending STATUS line not found"; echo "full output:"; echo "$out" >&2; rm -rf "$d"; exit 1; }
  echo "$status_line" | grep -q "session reload" || { echo "FAIL: Test O reload_pending STATUS should mention session reload, got: $status_line"; rm -rf "$d"; exit 1; }
  echo "$status_line" | grep -q "reload-plugins" || { echo "FAIL: Test O reload_pending STATUS should mention reload-plugins, got: $status_line"; rm -rf "$d"; exit 1; }

  # The STATUS line must NOT contain "needs healing" (this distinguishes it from stale)
  echo "$status_line" | grep -q "needs healing" && { echo "FAIL: Test O reload_pending STATUS must NOT mention needs healing, got: $status_line"; rm -rf "$d"; exit 1; }

  rm -rf "$d"

  # === Test P: Bedrock model override detection and healing ===
  # This test creates fixtures for models.json with various states and verifies:
  # - pi absent: checks skipped entirely
  # - models.json absent: rows reported as MISSING
  # - correct values: rows reported as OK
  # - wrong value: row reported as MISSING and fixed correctly
  # - malformed PLANNERS: rows reported as UNKNOWN
  # - malformed models.json: heal fails cleanly (not corrupting file)

  # Test P1: Bedrock checks skipped when pi is absent
  # Create fixture with correct models.json (should not matter since pi is absent)
  d=$(mktemp -d)
  j="$d/models.json"
  python3 -c "
import json
data = {'providers': {'amazon-bedrock': {'modelOverrides': {'global.moonshotai.kimi-k3': {'maxTokens': 120000}, 'models': [{'id': 'us.deepseek.r1-v1:0', 'maxTokens': 30000}]}}}}
with open('$j', 'w') as f:
    json.dump(data, f)
"
  out=$(SM_CHECKER_HARNESS=nonexistent "$script_abs" --report 2>&1)
  has_kimi=$(echo "$out" | grep "pi Bedrock override: kimi-k3" || true)
  has_deepseek=$(echo "$out" | grep "pi Bedrock override: deepseek-r1" || true)
  [ -z "$has_kimi" ] || { echo "FAIL: Test P1 expected kimi row skipped when pi absent, got: $has_kimi"; rm -rf "$d"; exit 1; }
  [ -z "$has_deepseek" ] || { echo "FAIL: Test P1 expected deepseek row skipped when pi absent, got: $has_deepseek"; rm -rf "$d"; exit 1; }
  rm -rf "$d"

  # Test P2: models.json absent -> both rows MISSING
  d=$(mktemp -d)
  home_backup="$HOME"
  HOME="$d"
  out=$(SM_CHECKER_HARNESS=pi "$script_abs" --report 2>&1)
  HOME="$home_backup"
  # Both should be MISSING
  kimi_row=$(echo "$out" | grep "pi Bedrock override: kimi-k3" || true)
  deepseek_row=$(echo "$out" | grep "pi Bedrock override: deepseek-r1" || true)
  echo "$kimi_row" | grep -q "\[!!\]" || { echo "FAIL: Test P2 expected kimi row MISSING, got: $kimi_row"; rm -rf "$d"; exit 1; }
  echo "$deepseek_row" | grep -q "\[!!\]" || { echo "FAIL: Test P2 expected deepseek row MISSING, got: $deepseek_row"; rm -rf "$d"; exit 1; }
  rm -rf "$d"

  # Test P3: models.json present with correct values -> both rows OK
  d=$(mktemp -d)
  j="$d/.pi/agent/models.json"
  mkdir -p "$d/.pi/agent"
  python3 -c "
import json
data = {'providers': {'amazon-bedrock': {
    'modelOverrides': {'global.moonshotai.kimi-k3': {'maxTokens': 120000}},
    'models': [{'id': 'us.deepseek.r1-v1:0', 'maxTokens': 30000, 'api': 'bedrock-converse-stream', 'baseUrl': 'https://bedrock-runtime.us-east-1.amazonaws.com', 'name': 'DeepSeek R1', 'reasoning': True, 'contextWindow': 128000}]
}}}
with open('$j', 'w') as f:
    json.dump(data, f)
"
  home_backup="$HOME"
  HOME="$d"
  out=$(SM_CHECKER_HARNESS=pi "$script_abs" --report 2>&1)
  HOME="$home_backup"
  # Both should be OK
  kimi_row=$(echo "$out" | grep "pi Bedrock override: kimi-k3" || true)
  deepseek_row=$(echo "$out" | grep "pi Bedrock override: deepseek-r1" || true)
  echo "$kimi_row" | grep -q "\[ok\]" || { echo "FAIL: Test P3 expected kimi row OK, got: $kimi_row"; rm -rf "$d"; exit 1; }
  echo "$deepseek_row" | grep -q "\[ok\]" || { echo "FAIL: Test P3 expected deepseek row OK, got: $deepseek_row"; rm -rf "$d"; exit 1; }
  rm -rf "$d"

  # Test P4: models.json present with wrong value for one model only -> that row MISSING, other OK
  d=$(mktemp -d)
  j="$d/.pi/agent/models.json"
  mkdir -p "$d/.pi/agent"
  # kimi-k3 has wrong value (too high), deepseek-r1 is correct
  python3 -c "
import json
data = {'providers': {'amazon-bedrock': {
    'modelOverrides': {'global.moonshotai.kimi-k3': {'maxTokens': 200000}},
    'models': [{'id': 'us.deepseek.r1-v1:0', 'maxTokens': 30000, 'api': 'bedrock-converse-stream', 'baseUrl': 'https://bedrock-runtime.us-east-1.amazonaws.com', 'name': 'DeepSeek R1', 'reasoning': True, 'contextWindow': 128000}]
}}}
with open('$j', 'w') as f:
    json.dump(data, f)
"
  home_backup="$HOME"
  HOME="$d"
  out=$(SM_CHECKER_HARNESS=pi "$script_abs" --report 2>&1)
  HOME="$home_backup"
  # kimi-k3 should be MISSING (wrong value), deepseek-r1 should be OK
  kimi_row=$(echo "$out" | grep "pi Bedrock override: kimi-k3" || true)
  deepseek_row=$(echo "$out" | grep "pi Bedrock override: deepseek-r1" || true)
  echo "$kimi_row" | grep -q "\[!!\]" || { echo "FAIL: Test P4 expected kimi row MISSING due to wrong value, got: $kimi_row"; rm -rf "$d"; exit 1; }
  echo "$deepseek_row" | grep -q "\[ok\]" || { echo "FAIL: Test P4 expected deepseek row OK, got: $deepseek_row"; rm -rf "$d"; exit 1; }
  rm -rf "$d"

  # Test P5: malformed PLANNERS -> both rows UNKNOWN (not silent pass)
  # Bug 3 fix: create a temp fixture file with malformed/missing PLANNERS, point at via SM_PLANCOMMITTEE_PATH
  d=$(mktemp -d)
  broken_script="$d/broken-plan.sh"
  # Create a plan-committee.sh that has NO PLANNERS array at all (malformed from the parser's view)
  cat > "$broken_script" << 'BROKEN_EOF'
#!/usr/bin/env bash
set -uo pipefail
# No PLANNERS array - this is malformed
PROVIDER="amazon-bedrock"
BROKEN_EOF
  
  # Use --json to verify status is UNKNOWN (not MISSING, not silent pass)
  SM_PLANCOMMITTEE_PATH="$broken_script" SM_CHECKER_HARNESS=pi "$script_abs" --json 2>/dev/null > "$d/report.json"
  
  # Check kimi-k3 is UNKNOWN
  kimi_status=$(python3 -c "
import json,sys
data=json.load(open('$d/report.json'))
for x in data:
    if x['name']=='pi Bedrock override: kimi-k3':
        print(x['status'])
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null)
  [ "$kimi_status" = "UNKNOWN" ] || { echo "FAIL: Test P5 expected kimi-k3 UNKNOWN, got '$kimi_status'"; rm -rf "$d"; exit 1; }
  
  # Check deepseek-r1 is UNKNOWN
  deepseek_status=$(python3 -c "
import json,sys
data=json.load(open('$d/report.json'))
for x in data:
    if x['name']=='pi Bedrock override: deepseek-r1':
        print(x['status'])
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null)
  [ "$deepseek_status" = "UNKNOWN" ] || { echo "FAIL: Test P5 expected deepseek-r1 UNKNOWN, got '$deepseek_status'"; rm -rf "$d"; exit 1; }
  
  rm -rf "$d"

  # Test P6: heal actually fixes a wrong value without destroying other content
  # Finding 3 fix: add sibling keys (customName, contextWindow) to the override object
  # to actually catch the 'whole-object-replace destroys sibling keys' bug
  d=$(mktemp -d)
  j="$d/.pi/agent/models.json"
  mkdir -p "$d/.pi/agent"
  # Create models.json with wrong kimi-k3 value AND sibling keys that MUST be preserved
  python3 -c "
import json
data = {'other_provider': {'models': []}, 'providers': {'amazon-bedrock': {
    'modelOverrides': {'global.moonshotai.kimi-k3': {'maxTokens': 200000, 'customName': 'test-label', 'contextWindow': 999999}},
    'models': [{'id': 'us.deepseek.r1-v1:0', 'maxTokens': 30000, 'api': 'bedrock-converse-stream', 'baseUrl': 'https://bedrock-runtime.us-east-1.amazonaws.com', 'name': 'DeepSeek R1', 'reasoning': True, 'contextWindow': 128000}]
}}}
with open('$j', 'w') as f:
    json.dump(data, f)
"
  home_backup="$HOME"
  HOME="$d"
  # Simulate heal by calling _heal_bedrock_kimi_k3 directly (it reads models_json from $HOME/.pi/agent/models.json)
  out=$(SM_CHECKER_HARNESS=pi bash -c "source '$script_abs'; _heal_bedrock_kimi_k3 global.moonshotai.kimi-k3" 2>&1)
  HOME="$home_backup"
  
  # Verify heal succeeded
  echo "$out" | grep -q "\[OK\].*fixed" || { echo "FAIL: Test P6 heal expected success, got: $out"; rm -rf "$d"; exit 1; }
  
  # Verify file still has valid JSON and unrelated content preserved
  python3 -c "import json; json.loads(open('$j').read())" || { echo "FAIL: Test P6 file corrupted to invalid JSON"; rm -rf "$d"; exit 1; }
  grep -q '"other_provider"' "$j" || { echo "FAIL: Test P6 unrelated content (other_provider) lost after heal"; rm -rf "$d"; exit 1; }
  
  # Verify kimi-k3 maxTokens was corrected to safe target (120000)
  # AND sibling keys were preserved (Finding 3 fix: this catches the whole-object-replace bug)
  python3 -c "
import json
data = json.load(open('$j'))
override = data.get('providers', {}).get('amazon-bedrock', {}).get('modelOverrides', {}).get('global.moonshotai.kimi-k3', {})
maxTokens = override.get('maxTokens')
customName = override.get('customName')
contextWindow = override.get('contextWindow')
if maxTokens != 120000:
    print(f'FAIL: Test P6 expected maxTokens=120000, got {maxTokens}')
    sys.exit(1)
if customName != 'test-label':
    print(f'FAIL: Test P6 expected customName=test-label preserved, got {customName}')
    sys.exit(1)
if contextWindow != 999999:
    print(f'FAIL: Test P6 expected contextWindow=999999 preserved, got {contextWindow}')
    sys.exit(1)
"
  [ $? -eq 0 ] || { echo "FAIL: Test P6 kimi-k3 override not corrected or sibling keys lost"; rm -rf "$d"; exit 1; }
  
  rm -rf "$d"

  # Test P7: malformed models.json -> heal fails cleanly (nonzero exit) without corruption
  d=$(mktemp -d)
  j="$d/.pi/agent/models.json"
  mkdir -p "$d/.pi/agent"
  echo "{invalid json" > "$j"
  
  home_backup="$HOME"
  HOME="$d"
  out=$(SM_CHECKER_HARNESS=pi bash -c "source '$script_abs'; _heal_bedrock_kimi_k3 global.moonshotai.kimi-k3" 2>&1)
  heal_rc=$?
  HOME="$home_backup"
  
  [ "$heal_rc" -ne 0 ] || { echo "FAIL: Test P7 expected heal failure on malformed JSON, got rc=0"; rm -rf "$d"; exit 1; }
  echo "$out" | grep -q -E 'malformed|failed' || { echo "FAIL: Test P7 expected clear failure message, got: $out"; rm -rf "$d"; exit 1; }
  
  # Verify file still exists (wasn't deleted by temp file cleanup)
  [ -f "$j" ] || { echo "FAIL: Test P7 malformed JSON file disappeared"; rm -rf "$d"; exit 1; }
  
  # Verify content unchanged (no partial writes)
  [ "$(cat "$j")" = '{invalid json' ] || { echo "FAIL: Test P7 malformed JSON file was modified"; rm -rf "$d"; exit 1; }
  
  rm -rf "$d"

  # Test P8: heal with --yes mode works
  d=$(mktemp -d)
  j="$d/.pi/agent/models.json"
  mkdir -p "$d/.pi/agent"
  python3 -c "
import json
data = {'providers': {'amazon-bedrock': {
    'modelOverrides': {'global.moonshotai.kimi-k3': {'maxTokens': 200000}}
}}}
with open('$j', 'w') as f:
    json.dump(data, f)
"
  
  home_backup="$HOME"
  HOME="$d"
  # Run doctor.sh --heal --yes
  out=$("$script_abs" --heal --yes 2>&1)
  HOME="$home_backup"
  
  # Verify kimi-k3 heal happened
  echo "$out" | grep -q "kimi-k3 Bedrock override fixed" || { echo "FAIL: Test P8 heal --yes didn't fix kimi-k3, output: $out"; rm -rf "$d"; exit 1; }
  
  # Verify kimi-k3 file was updated
  python3 -c "
import json
data = json.load(open('$j'))
val = data.get('providers', {}).get('amazon-bedrock', {}).get('modelOverrides', {}).get('global.moonshotai.kimi-k3', {}).get('maxTokens')
if val != 120000:
    print(f'FAIL: Test P8 expected kimi-k3 maxTokens=120000 after heal, got {val}')
    sys.exit(1)
"
  [ $? -eq 0 ] || { echo "FAIL: Test P8 kimi-k3 not corrected after heal --yes"; rm -rf "$d"; exit 1; }
  
  # Finding 3 fix: verify deepseek-r1 entry was also created correctly
  python3 -c "
import json
data = json.load(open('$j'))
models = data.get('providers', {}).get('amazon-bedrock', {}).get('models', [])
if not isinstance(models, list):
    print('FAIL: Test P8 expected models array')
    sys.exit(1)
found = False
for entry in models:
    if isinstance(entry, dict) and entry.get('id') == 'us.deepseek.r1-v1:0':
        maxTokens = entry.get('maxTokens')
        if not isinstance(maxTokens, (int, float)) or maxTokens > 32768:
            print(f'FAIL: Test P8 expected deepseek-r1 maxTokens<=32768, got {maxTokens}')
            sys.exit(1)
        found = True
        break
if not found:
    print('FAIL: Test P8 expected deepseek-r1 entry in models[]')
    sys.exit(1)
"
  [ $? -eq 0 ] || { echo "FAIL: Test P8 deepseek-r1 not created correctly after heal --yes"; rm -rf "$d"; exit 1; }
  
  rm -rf "$d"

  # Test P9: test for round-2 Finding 1 (fresh HOME/no-.pi-directory) regression
  # Fix: create a COMPLETELY fresh temp HOME with NO .pi directory at all,
  # run doctor.sh --heal --yes, assert both kimi-k3 and deepseek-r1 entries were created
  # This tests the os.makedirs fix from round 2 that creates the parent directory
  d=$(mktemp -d)
  j="$d/.pi/agent/models.json"
  # DO NOT mkdir -p $d/.pi/agent - that's the exact bug fixture!
  
  home_backup="$HOME"
  HOME="$d"
  # Run doctor.sh --heal --yes against completely fresh HOME (no .pi directory)
  out=$("$script_abs" --heal --yes 2>&1)
  HOME="$home_backup"
  
  # Both fixes should have succeeded
  echo "$out" | grep -q "kimi-k3 Bedrock override fixed" || { echo "FAIL: Test P9 heal --yes didn't fix kimi-k3, output: $out"; rm -rf "$d"; exit 1; }
  echo "$out" | grep -q "deepseek-r1 Bedrock override fixed" || { echo "FAIL: Test P9 heal --yes didn't fix deepseek-r1, output: $out"; rm -rf "$d"; exit 1; }
  
  # Verify kimi-k3 maxTokens was corrected to safe target (120000)
  python3 -c "
import json
data = json.load(open('$j'))
val = data.get('providers', {}).get('amazon-bedrock', {}).get('modelOverrides', {}).get('global.moonshotai.kimi-k3', {}).get('maxTokens')
if val != 120000:
    print(f'FAIL: Test P9 expected kimi-k3 maxTokens=120000, got {val}')
    sys.exit(1)
"
  [ $? -eq 0 ] || { echo "FAIL: Test P9 kimi-k3 not corrected after heal --yes"; rm -rf "$d"; exit 1; }
  
  # Verify deepseek-r1 entry was created in models[]
  python3 -c "
import json
data = json.load(open('$j'))
models = data.get('providers', {}).get('amazon-bedrock', {}).get('models', [])
if not isinstance(models, list):
    print('FAIL: Test P9 expected models array')
    sys.exit(1)
found = False
for entry in models:
    if isinstance(entry, dict) and entry.get('id') == 'us.deepseek.r1-v1:0':
        maxTokens = entry.get('maxTokens')
        if not isinstance(maxTokens, (int, float)) or maxTokens > 32768:
            print(f'FAIL: Test P9 expected deepseek-r1 maxTokens<=32768, got {maxTokens}')
            sys.exit(1)
        found = True
        break
if not found:
    print('FAIL: Test P9 expected deepseek-r1 entry in models[]')
    sys.exit(1)
"
  [ $? -eq 0 ] || { echo "FAIL: Test P9 deepseek-r1 not created correctly after heal --yes"; rm -rf "$d"; exit 1; }
  
  rm -rf "$d"

  # Test P10: consolidated test for all invalid numeric values (round 4 Finding 1+2 fix)
  # Tests: true, false, 0, -1, 1.5, NaN, Infinity, -Infinity all report MISSING
  # This consolidates a failing pattern: each round introduced a new edge case
  # that slipped through because the check was patched case-by-case instead of
  # being robust from the start. This test verifies the consolidated check works.
  d=$(mktemp -d)
  j="$d/.pi/agent/models.json"
  mkdir -p "$d/.pi/agent"
  
  # Test kimi-k3: each invalid value should report MISSING
  for invalid_val in "true" "false" "0" "-1" "1.5" "NaN" "Infinity" "-Infinity"; do
    python3 -c "
import json, sys

def parse_json_value(s):
    s = s.strip()
    if s == 'true':
        return True
    elif s == 'false':
        return False
    elif s == 'null':
        return None
    elif s.lower() == 'nan':
        return float('nan')
    elif s.lower() == 'infinity':
        return float('inf')
    elif s.lower() == '-infinity':
        return float('-inf')
    else:
        try:
            if '.' in s:
                return float(s)
            else:
                return int(s)
        except ValueError:
            return s

val = '''$invalid_val'''
data_val = parse_json_value(val)

base = {
    'providers': {
        'amazon-bedrock': {
            'modelOverrides': {'global.moonshotai.kimi-k3': {'maxTokens': 120000}}
        }
    }
}
base['providers']['amazon-bedrock']['modelOverrides']['global.moonshotai.kimi-k3']['maxTokens'] = data_val

with open('$j', 'w') as f:
    json.dump(base, f)
"
    
    status=$(HOME="$d" SM_CHECKER_HARNESS=pi "$script_abs" --json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for x in data:
    if x['name'] == 'pi Bedrock override: kimi-k3':
        print(x['status'])
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null)
    
    [ "$status" = "MISSING" ] || { echo "FAIL: Test P10 kimi-k3 with maxTokens=$invalid_val expected MISSING, got $status"; rm -rf "$d"; exit 1; }
  done
  
  # Test deepseek-r1: each invalid value should report MISSING (Finding 2 fix)
  for invalid_val in "true" "false" "0" "-1" "1.5" "NaN" "Infinity" "-Infinity"; do
    python3 -c "
import json, sys

def parse_json_value(s):
    s = s.strip()
    if s == 'true':
        return True
    elif s == 'false':
        return False
    elif s == 'null':
        return None
    elif s.lower() == 'nan':
        return float('nan')
    elif s.lower() == 'infinity':
        return float('inf')
    elif s.lower() == '-infinity':
        return float('-inf')
    else:
        try:
            if '.' in s:
                return float(s)
            else:
                return int(s)
        except ValueError:
            return s

val = '''$invalid_val'''
data_val = parse_json_value(val)

base = {
    'providers': {
        'amazon-bedrock': {
            'models': [{'id': 'us.deepseek.r1-v1:0', 'maxTokens': 30000}]
        }
    }
}
base['providers']['amazon-bedrock']['models'][0]['maxTokens'] = data_val

with open('$j', 'w') as f:
    json.dump(base, f)
"
    
    status=$(HOME="$d" SM_CHECKER_HARNESS=pi "$script_abs" --json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for x in data:
    if x['name'] == 'pi Bedrock override: deepseek-r1':
        print(x['status'])
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null)
    
    [ "$status" = "MISSING" ] || { echo "FAIL: Test P10 deepseek-r1 with maxTokens=$invalid_val expected MISSING, got $status"; rm -rf "$d"; exit 1; }
  done
  
  rm -rf "$d"

  # Test P11: _bedrock_fix_deepseek_r1 preserves custom fields (round 5 finding)
  # Before fix: full object replacement destroyed any custom keys
  # After fix: merge preserves custom keys like 'customKey': 'must-survive'
  d=$(mktemp -d)
  j="$d/.pi/agent/models.json"
  mkdir -p "$d/.pi/agent"
  
  # Create deepseek-r1 entry with wrong maxTokens and a custom field
  python3 -c "
import json
data = {
    'providers': {
        'amazon-bedrock': {
            'models': [{
                'id': 'us.deepseek.r1-v1:0',
                'maxTokens': 99999,  # wrong value
                'customKey': 'must-survive',  # must be preserved
                'api': 'custom-api',
                'contextWindow': 128000
            }]
        }
    }
}
with open('$j', 'w') as f:
    json.dump(data, f)
"
  
  home_backup="$HOME"
  HOME="$d"
  out=$(SM_CHECKER_HARNESS=pi "$script_abs" --heal --yes 2>&1)
  HOME="$home_backup"
  
  # Verify heal succeeded
  echo "$out" | grep -q "deepseek-r1 Bedrock override fixed" || { echo "FAIL: Test P11 heal --yes didn't fix deepseek-r1, output: $out"; rm -rf "$d"; exit 1; }
  
  # Verify custom field survived
  python3 -c "
import json
data = json.load(open('$j'))
models = data.get('providers', {}).get('amazon-bedrock', {}).get('models', [])
found = False
for entry in models:
    if isinstance(entry, dict) and entry.get('id') == 'us.deepseek.r1-v1:0':
        # Verify canonical fields are correct
        if entry.get('maxTokens') != 30000:
            print(f'FAIL: Test P11 expected maxTokens=30000, got {entry.get(\"maxTokens\")}')
            sys.exit(1)
        # Verify custom field survived
        if entry.get('customKey') != 'must-survive':
            print(f'FAIL: Test P11 expected customKey=must-survive, got {entry.get(\"customKey\")}')
            sys.exit(1)
        # Verify other canonical fields are correct
        if entry.get('api') != 'bedrock-converse-stream':
            print(f'FAIL: Test P11 expected api=bedrock-converse-stream, got {entry.get(\"api\")}')
            sys.exit(1)
        if entry.get('baseUrl') != 'https://bedrock-runtime.us-east-1.amazonaws.com':
            print(f'FAIL: Test P11 expected baseUrl, got {entry.get(\"baseUrl\")}')
            sys.exit(1)
        found = True
        break
if not found:
    print('FAIL: Test P11 deepseek-r1 entry not found')
    sys.exit(1)
"
  [ $? -eq 0 ] || { echo "FAIL: Test P11 deepseek-r1 custom field not preserved"; rm -rf "$d"; exit 1; }
  
  rm -rf "$d"

  # Test P12: regression test for round-6/7 apostrophe-in-HOME-path fix
  d="$(mktemp -d)/apos'''home"
  mkdir -p "$d/.pi/agent"
  j="$d/.pi/agent/models.json"
  P12_JSON_PATH="$j" python3 -c "
import json, os
jp = os.environ['P12_JSON_PATH']
data = {
    'providers': {
        'amazon-bedrock': {
            'modelOverrides': {'global.moonshotai.kimi-k3': {'maxTokens': 200000}},
            'models': [{'id': 'us.deepseek.r1-v1:0', 'maxTokens': 50000}]
        }
    }
}
with open(jp, 'w') as f:
    json.dump(data, f)
"
  home_backup="$HOME"
  HOME="$d"
  out=$("$script_abs" --heal --yes 2>&1)
  HOME="$home_backup"
  echo "$out" | grep -q "kimi-k3 Bedrock override fixed" || { echo "FAIL: Test P12 heal didn't fix kimi-k3, output: $out"; rm -rf "$d"; exit 1; }
  echo "$out" | grep -q "deepseek-r1 Bedrock override fixed" || { echo "FAIL: Test P12 heal didn't fix deepseek-r1, output: $out"; rm -rf "$d"; exit 1; }
  P12_JSON_PATH="$j" python3 -c "
import json, os, sys
jp = os.environ['P12_JSON_PATH']
data = json.load(open(jp))
val = data.get('providers', {}).get('amazon-bedrock', {}).get('modelOverrides', {}).get('global.moonshotai.kimi-k3', {}).get('maxTokens')
if val != 120000:
    print(f'FAIL: Test P12 expected kimi-k3 maxTokens=120000, got {val}')
    sys.exit(1)
"
  [ $? -eq 0 ] || { echo "FAIL: Test P12 kimi-k3 not correctly fixed"; rm -rf "$d"; exit 1; }
  P12_JSON_PATH="$j" python3 -c "
import json, os, sys
jp = os.environ['P12_JSON_PATH']
data = json.load(open(jp))
models = data.get('providers', {}).get('amazon-bedrock', {}).get('models', [])
for entry in models:
    if isinstance(entry, dict) and entry.get('id') == 'us.deepseek.r1-v1:0':
        val = entry.get('maxTokens')
        if val != 30000:
            print(f'FAIL: Test P12 expected deepseek-r1 maxTokens=30000, got {val}')
            sys.exit(1)
        break
else:
    print('FAIL: Test P12 deepseek-r1 entry not found')
    sys.exit(1)
"
  [ $? -eq 0 ] || { echo "FAIL: Test P12 deepseek-r1 not correctly fixed"; rm -rf "$d"; exit 1; }
  rm -rf "$d"

  # Test P13: _bedrock_get_model_id must work when doctor.sh invoked via symlink
  # Round 7 fix: avoid shadowing global $script_dir with local declaration
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  symlink_dir=$(mktemp -d)
  ln -sf "$script_dir/doctor.sh" "$symlink_dir/doctor"
  
  # Create a fixture with correct values
  d=$(mktemp -d)
  mkdir -p "$d/.pi/agent"
  j="$d/.pi/agent/models.json"
  python3 -c "
import json
data = {
    'providers': {
        'amazon-bedrock': {
            'modelOverrides': {'global.moonshotai.kimi-k3': {'maxTokens': 120000}},
            'models': [{'id': 'us.deepseek.r1-v1:0', 'maxTokens': 30000}]
        }
    }
}
with open('$j', 'w') as f:
    json.dump(data, f)
"
  
  home_backup="$HOME"
  HOME="$d"
  # Run via symlink
  out=$("$symlink_dir/doctor" --json 2>&1)
  HOME="$home_backup"
  
  # Both should be OK, not UNKNOWN
  kimi_status=$(echo "$out" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for x in data:
    if x['name']=='pi Bedrock override: kimi-k3':
        print(x['status'])
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null)
  [ "$kimi_status" = "OK" ] || { echo "FAIL: Test P13 kimi-k3 via symlink expected OK, got '$kimi_status'"; rm -rf "$d" "$symlink_dir"; exit 1; }
  
  deepseek_status=$(echo "$out" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for x in data:
    if x['name']=='pi Bedrock override: deepseek-r1':
        print(x['status'])
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null)
  [ "$deepseek_status" = "OK" ] || { echo "FAIL: Test P13 deepseek-r1 via symlink expected OK, got '$deepseek_status'"; rm -rf "$d" "$symlink_dir"; exit 1; }
  
  rm -rf "$d" "$symlink_dir"

  # === Test Q: skill discovery asymmetry detection + heal ===
  d=$(mktemp -d)
  # alpha: present in BOTH .claude/skills and .agents/skills -> OK, visible to both harnesses.
  mkdir -p "$d/.claude/skills/alpha" "$d/.agents/skills/alpha"
  echo "alpha claude copy" > "$d/.claude/skills/alpha/SKILL.md"
  echo "alpha agents copy" > "$d/.agents/skills/alpha/SKILL.md"
  # bravo: present ONLY under .claude/skills -> invisible to pi. .agents/skills/bravo does not exist
  # yet, so a safe, unambiguous heal-fix command should be offered.
  mkdir -p "$d/.claude/skills/bravo"
  echo "bravo real content" > "$d/.claude/skills/bravo/SKILL.md"
  # charlie: present ONLY under .pi/skills -> invisible to Claude Code. No heal offered for this
  # direction by design (this task's explicit scope: only build heal for the pi-invisible case).
  mkdir -p "$d/.pi/skills/charlie"
  echo "charlie real content" > "$d/.pi/skills/charlie/SKILL.md"
  # leaky: a .claude/skills entry that is a symlink resolving OUTSIDE the repo root entirely -- must be
  # reported as invisible-to-pi, but must NEVER be offered as a heal target (mirrors
  # bin/sync-worktree-skills.sh's own leaky-symlink guard for the identical underlying risk). The
  # external target lives under a SEPARATE mktemp dir, genuinely outside $d, not merely a sibling path
  # string that happens to still resolve inside it.
  external_q="$(mktemp -d)"
  echo "SENSITIVE_Q" > "$external_q/leaked.txt"
  ln -s "$external_q" "$d/.claude/skills/leaky"
  # a directory name that fails the safe-identifier check -- must be silently excluded from every row,
  # never crash the scan, never reach a constructed shell command.
  mkdir -p "$d/.claude/skills/bad;name"
  echo "unsafe name content" > "$d/.claude/skills/bad;name/SKILL.md"

  # isolate from the REAL installed secondmate plugin state (SM_SECONDMATE_MARKETPLACE_DIR/etc.) so
  # this test's --heal --yes never touches the real marketplace checkout or attempts a real network
  # fetch -- matching every other JSON/heal invocation earlier in this selfcheck. A nonexistent
  # marketplace dir makes _detect_secondmate_status report "missing" instantly, no I/O.
  q_lock_dir="$d/.q-lock"
  out_json=$(cd "$d" && GIT_CEILING_DIRECTORIES="$d" SM_SECONDMATE_MARKETPLACE_DIR="$d/.q-no-marketplace" SM_INSTALLED_PLUGINS_JSON="$d/.q-no-installed.json" SM_DOCTOR_LOCK_DIR="$q_lock_dir" "$script_abs" --json 2>/dev/null)
  q_check() {  # q_check <name> <expected_status>
    local got
    got=$(echo "$out_json" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for x in data:
    if x['name']=='$1':
        print(x['status']); sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null)
    [ "$got" = "$2" ] || { echo "FAIL: Test Q expected '$1' status '$2', got '$got'"; rm -rf "$d"; exit 1; }
  }
  q_check "skill discovery: alpha (pi+claude)" OK
  q_check "skill discovery: bravo (not visible to pi)" MISSING
  q_check "skill discovery: charlie (not visible to claude)" MISSING
  q_check "skill discovery: leaky (not visible to pi)" MISSING
  echo "$out_json" | grep -q '"name":"skill discovery: bad;name' && { echo "FAIL: Test Q unsafe name 'bad;name' leaked into a row"; rm -rf "$d"; exit 1; }

  # charlie's row must carry no auto-fix (empty fix field) -- no heal offered in this direction.
  charlie_fix=$(echo "$out_json" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for x in data:
    if x['name']=='skill discovery: charlie (not visible to claude)':
        print(x['fix']); sys.exit(0)
" 2>/dev/null)
  [ -z "$charlie_fix" ] || { echo "FAIL: Test Q charlie should have no auto-fix, got '$charlie_fix'"; rm -rf "$d"; exit 1; }

  # leaky's row must ALSO carry no auto-fix -- the whole point of the outside-repo-root guard.
  leaky_fix=$(echo "$out_json" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for x in data:
    if x['name']=='skill discovery: leaky (not visible to pi)':
        print(x['fix']); sys.exit(0)
" 2>/dev/null)
  [ -z "$leaky_fix" ] || { echo "FAIL: Test Q leaky should have no auto-fix (outside-repo symlink), got '$leaky_fix'"; rm -rf "$d"; exit 1; }

  # run --heal --yes: bravo should get healed (real copy at .agents/skills/bravo), charlie/leaky left
  # untouched (no fix offered), and no sensitive content from the leaky symlink must ever appear anywhere.
  heal_out=$(cd "$d" && GIT_CEILING_DIRECTORIES="$d" SM_SECONDMATE_MARKETPLACE_DIR="$d/.q-no-marketplace" SM_INSTALLED_PLUGINS_JSON="$d/.q-no-installed.json" SM_DOCTOR_LOCK_DIR="$q_lock_dir" "$script_abs" --heal --yes 2>&1)
  [ -f "$d/.agents/skills/bravo/SKILL.md" ] || { echo "FAIL: Test Q heal did not create .agents/skills/bravo"; echo "$heal_out" >&2; rm -rf "$d"; exit 1; }
  diff -q "$d/.claude/skills/bravo/SKILL.md" "$d/.agents/skills/bravo/SKILL.md" >/dev/null \
    || { echo "FAIL: Test Q healed bravo content differs from its real source"; rm -rf "$d"; exit 1; }
  [ ! -e "$d/.agents/skills/charlie" ] || { echo "FAIL: Test Q charlie should never get a .agents/skills entry (no heal offered)"; rm -rf "$d"; exit 1; }
  [ ! -e "$d/.agents/skills/leaky" ] || { echo "FAIL: Test Q leaky should never get a .agents/skills entry (outside-repo symlink)"; rm -rf "$d"; exit 1; }
  ! grep -rq 'SENSITIVE_Q' "$d/.agents" 2>/dev/null \
    || { echo "FAIL: Test Q SENSITIVE_Q (from outside the repo) leaked into .agents/skills"; rm -rf "$d"; exit 1; }

  # re-detect after heal: bravo must now report OK (pi+claude visible), proving the fresh detect() call
  # heal() already performs picks up the just-created .agents/skills/bravo with no special-casing.
  out_json2=$(cd "$d" && GIT_CEILING_DIRECTORIES="$d" SM_SECONDMATE_MARKETPLACE_DIR="$d/.q-no-marketplace" SM_INSTALLED_PLUGINS_JSON="$d/.q-no-installed.json" SM_DOCTOR_LOCK_DIR="$q_lock_dir" "$script_abs" --json 2>/dev/null)
  bravo_status2=$(echo "$out_json2" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for x in data:
    if x['name']=='skill discovery: bravo (pi+claude)':
        print(x['status']); sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null)
  [ "$bravo_status2" = "OK" ] || { echo "FAIL: Test Q post-heal bravo expected OK row, got '$bravo_status2'"; rm -rf "$d"; exit 1; }

  # mutation check: re-running the heal fix a second time (idempotent) must not error or duplicate.
  heal_out2=$(cd "$d" && GIT_CEILING_DIRECTORIES="$d" SM_SECONDMATE_MARKETPLACE_DIR="$d/.q-no-marketplace" SM_INSTALLED_PLUGINS_JSON="$d/.q-no-installed.json" SM_DOCTOR_LOCK_DIR="$q_lock_dir" "$script_abs" --heal --yes 2>&1)
  [ -f "$d/.agents/skills/bravo/SKILL.md" ] || { echo "FAIL: Test Q second heal run broke bravo"; rm -rf "$d"; exit 1; }

  rm -rf "$d" "$external_q"

  # === Test R: no project skills anywhere -> no skill discovery rows at all ===
  d=$(mktemp -d)
  # isolate from the REAL installed secondmate plugin state (SM_SECONDMATE_MARKETPLACE_DIR/etc.) so
  # this test's --heal --yes never touches the real marketplace checkout or attempts a real network
  # fetch -- matching every other JSON/heal invocation earlier in this selfcheck. A nonexistent
  # marketplace dir makes _detect_secondmate_status report "missing" instantly, no I/O.
  q_lock_dir="$d/.q-lock"
  out_json=$(cd "$d" && GIT_CEILING_DIRECTORIES="$d" SM_SECONDMATE_MARKETPLACE_DIR="$d/.q-no-marketplace" SM_INSTALLED_PLUGINS_JSON="$d/.q-no-installed.json" SM_DOCTOR_LOCK_DIR="$q_lock_dir" "$script_abs" --json 2>/dev/null)
  echo "$out_json" | grep -q '"name":"skill discovery:' \
    && { echo "FAIL: Test R expected zero skill discovery rows with no skill dirs present"; rm -rf "$d"; exit 1; }
  rm -rf "$d"

  echo ok; exit 0
fi

detect
case "${1:-}" in
  --json) emit_json;;
  --heal)
    if [ "${2:-}" = "--yes" ]; then
      heal 1; heal_rc=$?; echo; _reset_detect_state; detect; emit_table; exit $heal_rc
    else
      heal 0; heal_rc=$?; echo; _reset_detect_state; detect; emit_table; exit $heal_rc
    fi;;
  ""|--report) emit_table;;
  *) echo "usage: doctor.sh [--json|--heal [--yes]|--selfcheck]" >&2; exit 2;;
esac
[ "$core_missing" -eq 0 ]
