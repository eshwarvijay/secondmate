#!/usr/bin/env bash
# new-worktree.sh -- isolated git worktree per maker, asserting it is never the primary checkout.
# Each maker pane works in its own git worktree so parallel makers on one repo never collide, and the
# supervisor's primary checkout is never mutated by a worker.
#
#   new-worktree.sh --repo PATH --task ID [--base main]
# Prints:  <worktree-path> <branch>
# Worktrees live under $SM_WT_ROOT (default ~/.secondmate-worktrees).
set -euo pipefail

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
    --repo) repo="${2:?value required for $1}"; shift 2;;
    --task) task="${2:?value required for $1}"; shift 2;;
    --base) base="${2:?value required for $1}"; shift 2;;
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

# ponytail: the isolation assertion -- refuse if the worktree would land on the primary checkout.
[ "$wt" != "$primary" ] || { echo "isolation assertion failed: worktree == primary checkout" >&2; exit 1; }
[ -e "$wt" ] && { echo "worktree already exists: $wt" >&2; exit 1; }

mkdir -p "$wt_root"
git -C "$repo" worktree add -b "$branch" "$wt" "$base" >&2
echo "$wt $branch"
