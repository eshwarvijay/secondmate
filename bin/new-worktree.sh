#!/usr/bin/env bash
# new-worktree.sh -- isolated git worktree per maker, asserting it is never the primary checkout.
# Each maker pane works in its own git worktree so parallel makers on one repo never collide, and the
# supervisor's primary checkout is never mutated by a worker.
#
#   new-worktree.sh --repo PATH --task ID [--base main]
# Prints:  <worktree-path> <branch>
# Worktrees live under $SM_WT_ROOT (default ~/.secondmate-worktrees).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--selfcheck" ]; then
  t="$(mktemp -d)"; git init -q -b main "$t/proj" >/dev/null
  git -C "$t/proj" config user.email a@a; git -C "$t/proj" config user.name a
  echo x > "$t/proj/f"; git -C "$t/proj" add -A; git -C "$t/proj" commit -qm init
  fails=0
  rc=0; "$0" --repo "$t/proj" --task 'x/../../escape' >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: traversal task not rejected ($rc)"; fails=1; }
  rc=0; out="$(SM_WT_ROOT="$t/wts" "$0" --repo "$t/proj" --task good 2>/dev/null)" || rc=$?
  { [ "$rc" = 0 ] && [ -d "$t/wts/proj-good" ]; } || { echo "FAIL: normal spawn ($rc)"; fails=1; }
  rm -rf "$t"; [ "$fails" = 0 ] && echo ok; exit "$fails"
fi

repo="" task="" base="main"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; repo="$2"; shift 2;;
    --task) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; task="$2"; shift 2;;
    --base) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; base="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$repo" ] && [ -n "$task" ] || { echo "need --repo PATH --task ID" >&2; exit 2; }
# finding #5: a task with '/' or '..' would escape SM_WT_ROOT via git worktree add. Require a simple slug.
case "$task" in */*|*..*) echo "invalid --task '$task': use a simple slug (no '/' or '..')" >&2; exit 2;; esac

repo="$(cd "$repo" && pwd)"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo: $repo" >&2; exit 1; }
primary="$(git -C "$repo" rev-parse --show-toplevel)"

wt_root="${SM_WT_ROOT:-$HOME/.secondmate-worktrees}"
wt="$wt_root/$(basename "$primary")-$task"
branch="sm/$task"

mkdir -p "$wt_root"
# isolation assertion: the worktree root must live OUTSIDE the primary checkout, not merely differ (finding #1).
wt_root_abs="$(cd "$wt_root" && pwd -P)"   # physical path, to match git's canonical --show-toplevel
case "$wt_root_abs/" in "$primary"/*) echo "isolation failed: SM_WT_ROOT ($wt_root_abs) is inside the primary checkout $primary" >&2; exit 1;; esac
[ "$wt" != "$primary" ] || { echo "isolation assertion failed: worktree == primary checkout" >&2; exit 1; }
[ -e "$wt" ] && { echo "worktree already exists: $wt" >&2; exit 1; }
git -C "$repo" worktree add -b "$branch" "$wt" "$base" >&2
# mark this worktree as a maker session (never the primary checkout) so scope-guard.py's PreToolUse hook
# activates in it -- via the one shared marking call so this can't drift out of sync with the other
# maker-launch sites (see mark-maker.sh for why the marker lives OUTSIDE the worktree entirely).
"$SCRIPT_DIR/mark-maker.sh" --cwd "$wt" >&2
echo "$wt $branch"
