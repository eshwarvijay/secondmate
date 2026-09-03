#!/usr/bin/env bash
# mark-maker.sh -- the ONE shared call that marks a git worktree as a secondmate maker session so
# scope-guard.py's PreToolUse hook activates in it. Called by new-worktree.sh, herdr-pane.sh spawn, and
# manually after `herdr worktree create` (see SKILL.md step 2) -- every maker-launch path funnels through
# here so the marking logic can't drift out of sync across call sites.
#
#   mark-maker.sh [--cwd DIR]
#   mark-maker.sh --selfcheck
#
# Writes the activation marker OUTSIDE the worktree entirely (default ~/.secondmate-markers, override
# with SM_MARKER_ROOT), keyed by the worktree's realpath via `scope-guard.py markerpath`. Living outside
# the worktree means scope-guard.py's own path-confinement (Bash/Read/Edit/Write/NotebookEdit) already
# denies the marked session from writing or deleting its own marker -- no env var or other in-process
# state needed, and unlike an env var this is a real file that survives every fresh PreToolUse subprocess.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--selfcheck" ]; then
  t="$(mktemp -d)"; git init -q -b main "$t/proj" >/dev/null
  git -C "$t/proj" config user.email a@a; git -C "$t/proj" config user.name a
  echo x > "$t/proj/f"; git -C "$t/proj" add -A; git -C "$t/proj" commit -qm init
  git -C "$t/proj" worktree add -q -b feat "$t/wt" main
  fails=0
  rc=0; SM_MARKER_ROOT="$t/markers" "$0" --cwd "$t/wt" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: mark-maker exit $rc"; fails=1; }
  root="$(cd "$t/wt" && pwd -P)"
  marker="$(SM_MARKER_ROOT="$t/markers" python3 "$SCRIPT_DIR/scope-guard.py" markerpath "$root")"
  [ -f "$marker" ] || { echo "FAIL: marker not created at $marker"; fails=1; }
  case "$marker" in "$root"/*) echo "FAIL: marker lives inside the worktree ($marker)"; fails=1;; esac
  rm -rf "$t"; [ "$fails" = 0 ] && echo ok; exit "$fails"
fi

cwd="${PWD}"
while [ $# -gt 0 ]; do case "$1" in
  --cwd) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; cwd="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git worktree: $cwd" >&2; exit 1; }
root="$(git -C "$cwd" rev-parse --show-toplevel)" || { echo "git rev-parse --show-toplevel failed" >&2; exit 1; }
root="$(cd "$root" && pwd -P)"  # physical/realpath -- must match scope-guard.py's os.path.realpath

marker="$(python3 "$SCRIPT_DIR/scope-guard.py" markerpath "$root")"
mkdir -p "$(dirname "$marker")"
printf 'root=%s\n' "$root" > "$marker"
echo "marked: $root -> $marker"
