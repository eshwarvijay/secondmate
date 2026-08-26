#!/usr/bin/env bash
# new-worktree.sh -- isolated worktree per maker (steal #5, from firstmate fm-spawn.sh's isolation assertion).
# Each maker pane works in its own git worktree so parallel makers on one repo never collide, and the
# supervisor's primary checkout is never mutated by a worker.
#
#   new-worktree.sh --repo PATH --task ID [--base main]
# Prints:  <worktree-path> <branch>
# Worktrees live under $SM_WT_ROOT (default ~/.fm-worktrees).
set -euo pipefail

repo="" task="" base="main"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2;;
    --task) task="$2"; shift 2;;
    --base) base="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$repo" ] && [ -n "$task" ] || { echo "need --repo PATH --task ID" >&2; exit 2; }

repo="$(cd "$repo" && pwd)"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo: $repo" >&2; exit 1; }
primary="$(git -C "$repo" rev-parse --show-toplevel)"

wt_root="${SM_WT_ROOT:-$HOME/.fm-worktrees}"
wt="$wt_root/$(basename "$primary")-$task"
branch="fm/$task"

# ponytail: the isolation assertion -- refuse if the worktree would land on the primary checkout.
[ "$wt" != "$primary" ] || { echo "isolation assertion failed: worktree == primary checkout" >&2; exit 1; }
[ -e "$wt" ] && { echo "worktree already exists: $wt" >&2; exit 1; }

mkdir -p "$wt_root"
git -C "$repo" worktree add -b "$branch" "$wt" "$base" >&2
echo "$wt $branch"
