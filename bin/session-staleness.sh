#!/usr/bin/env bash
# SessionStart hook: auto-surface secondmate plugin staleness so no human needs to run
# /secondmate-doctor manually. Reuses doctor.sh's `--staleness-json` (itself a thin wrapper
# around _detect_secondmate_status) -- the SHA/version diffing lives in exactly one place.
# Advisory only: never heals, never blocks. Emits nothing when status is ok. Always exits 0.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--selfcheck" ]; then
  # Exercises the REAL CLI path (this exact script, invoked as a real subprocess, calling the REAL
  # doctor.sh --staleness-json against scratch marketplace/installed_plugins.json fixtures) -- never
  # a reimplementation of doctor.sh's own SHA/version comparison.
  t="$(mktemp -d)"; fails=0

  mk_marketplace() {  # mk_marketplace <dir> <version>
    local dir="$1" v="$2"
    mkdir -p "$dir/.claude-plugin"
    git -C "$dir" init -q -b main 2>/dev/null || true
    git -C "$dir" config user.email t@t.com 2>/dev/null
    git -C "$dir" config user.name t 2>/dev/null
    printf '{"name":"secondmate","version":"%s"}\n' "$v" > "$dir/.claude-plugin/plugin.json"
    git -C "$dir" add -A 2>/dev/null || true
    git -C "$dir" commit -q -m "v$v" 2>/dev/null || true
    git -C "$dir" rev-parse HEAD 2>/dev/null
  }
  mk_installed_json() {  # mk_installed_json <path> <sha> <version>
    printf '{"plugins":{"secondmate@secondmate":[{"scope":"user","installPath":"/tmp/x","version":"%s","gitCommitSha":"%s"}]}}' "$3" "$2" > "$1"
  }

  # ---- Test 1: stale -> advisory line naming the state, exit 0 ----
  d="$t/stale"; mkdir -p "$d"
  sha=$(mk_marketplace "$d/mkt" "9.9.9")
  j="$d/plugins.json"; mk_installed_json "$j" "deadbeef" "9.9.7"
  rc=0; out="$(SM_SECONDMATE_MARKETPLACE_DIR="$d/mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" "$0" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: stale case should exit 0, got $rc"; fails=1; }
  echo "$out" | grep -qi "stale" || { echo "FAIL: expected 'stale' in advisory output, got: $out"; fails=1; }
  echo "$out" | grep -q "/secondmate-doctor" || { echo "FAIL: expected the /secondmate-doctor pointer, got: $out"; fails=1; }

  # ---- Test 2: ok (sha + version both match running plugin.json's own version) -> no output, exit 0 ----
  d="$t/ok"; mkdir -p "$d"
  running_version=$(python3 -c "import json; print(json.load(open('$SCRIPT_DIR/../.claude-plugin/plugin.json'))['version'])")
  sha=$(mk_marketplace "$d/mkt" "$running_version")
  j="$d/plugins.json"; mk_installed_json "$j" "$sha" "$running_version"
  rc=0; out="$(SM_SECONDMATE_MARKETPLACE_DIR="$d/mkt" SM_INSTALLED_PLUGINS_JSON="$j" SM_DOCTOR_LOCK_DIR="$d/lock" "$0" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: ok case should exit 0, got $rc"; fails=1; }
  [ -z "$out" ] || { echo "FAIL: ok case should print nothing, got: $out"; fails=1; }

  # ---- Test 3: unknown (missing installed_plugins.json) -> advisory line naming the state, exit 0 ----
  d="$t/unknown"; mkdir -p "$d"
  mk_marketplace "$d/mkt" "9.9.9" >/dev/null
  rc=0; out="$(SM_SECONDMATE_MARKETPLACE_DIR="$d/mkt" SM_INSTALLED_PLUGINS_JSON="$d/nope.json" SM_DOCTOR_LOCK_DIR="$d/lock" "$0" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: unknown case should exit 0, got $rc"; fails=1; }
  echo "$out" | grep -qi "unknown" || { echo "FAIL: expected 'unknown' in advisory output, got: $out"; fails=1; }

  rm -rf "$t"
  [ "$fails" = 0 ] && echo ok
  exit "$fails"
fi

status_json="$("$SCRIPT_DIR/doctor.sh" --staleness-json 2>/dev/null)" || status_json=""
status=$(printf '%s' "$status_json" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('status',''))
except Exception:
    print('')" 2>/dev/null)
details=$(printf '%s' "$status_json" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('details',''))
except Exception:
    print('')" 2>/dev/null)

if [ -n "$status" ] && [ "$status" != "ok" ]; then
  printf 'secondmate plugin: %s%s — run /secondmate-doctor to see details\n' "$status" "${details:+ ($details)}"
fi
exit 0
