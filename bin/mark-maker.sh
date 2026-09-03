#!/usr/bin/env bash
# mark-maker.sh -- mark a git worktree as a secondmate maker session so scope-guard.py activates in it.
# Called by new-worktree.sh, herdr-pane.sh spawn, and manually after `herdr worktree create`.
#
#   mark-maker.sh [--cwd DIR]
#   mark-maker.sh --selfcheck
#
# Drops a marker file in the worktree's per-worktree git admin dir (never the working tree, can't be
# spoofed by an ordinary file). Also exports SM_WORKTREE_ROOT so the session remembers its root even if
# the marker is later deleted (defense-in-depth for finding #1).
set -euo pipefail

if [ "${1:-}" = "--selfcheck" ]; then
  t="$(mktemp -d)"; git init -q -b main "$t/proj" >/dev/null
  git -C "$t/proj" config user.email a@a; git -C "$t/proj" config user.name a
  echo x > "$t/proj/f"; git -C "$t/proj" add -A; git -C "$t/proj" commit -qm init
  git -C "$t/proj" worktree add -q -b feat "$t/wt" main
  fails=0
  rc=0; "$0" --cwd "$t/wt" >/dev/null 2>&1 || rc=$?; [ "$rc" = 0 ] || { echo "FAIL: mark-maker exit $rc"; fails=1; }
  marker="$(git -C "$t/wt" rev-parse --git-path secondmate-maker.marker 2>/dev/null)"
  [ -f "$marker" ] || { echo "FAIL: marker not created"; fails=1; }
  rm -rf "$t"; [ "$fails" = 0 ] && echo ok; exit "$fails"
fi

cwd="${PWD}"
while [ $# -gt 0 ]; do case "$1" in
  --cwd) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; cwd="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git worktree: $cwd" >&2; exit 1; }
marker="$(git -C "$cwd" rev-parse --git-path secondmate-maker.marker 2>/dev/null)" || { echo "git rev-parse --git-path failed" >&2; exit 1; }

# Resolve relative marker paths relative to cwd
if [[ ! "$marker" = /* ]]; then
  marker="$cwd/$marker"
fi

mkdir -p "$(dirname "$marker")"
printf 'marked-by=mark-maker.sh\n' > "$marker"

# Export SM_WORKTREE_ROOT so even if the marker is deleted, the session remembers (finding #1 defense)
root="$(git -C "$cwd" rev-parse --show-toplevel)" || { echo "git rev-parse --show-toplevel failed" >&2; exit 1; }
export SM_WORKTREE_ROOT="$(cd "$root" && pwd -P)"  # realpath
echo "marked: $cwd (SM_WORKTREE_ROOT=$SM_WORKTREE_ROOT)"
