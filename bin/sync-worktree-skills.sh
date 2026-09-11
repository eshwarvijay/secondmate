#!/usr/bin/env bash
# sync-worktree-skills.sh -- backfills gitignored project-local .claude/skills/ directories into a
# freshly created git worktree.
#
# The bug this fixes: project-local Claude Code skills live in .claude/skills/<name>/ directories -- a
# convention distinct from secondmate's own marketplace-based plugin skills. In real repos,
# .claude/skills/ is commonly gitignored (confirmed: a real user repo has `**/.claude/skills/` in its
# .gitignore), possibly at ANY depth in a monorepo. `git worktree add` -- used both by
# new-worktree.sh's headless path AND by the external `herdr worktree create` tool secondmate doesn't
# own -- only ever populates a new worktree from committed, tracked content; gitignored files never
# propagate. So a maker/supervisor session operating inside a secondmate-created worktree hits
# "Unknown skill: ..." for a project-local skill that exists fine in the primary checkout, simply
# because the directory is genuinely absent from the worktree.
#
#   sync-worktree-skills.sh --primary <path> --worktree <path>
#   sync-worktree-skills.sh --selfcheck
#
# Scope is deliberately narrow: .claude/skills/ ONLY, at any depth under --primary (monorepo-safe --
# e.g. <repo>/some-subproject/.claude/skills/<name>/). This does NOT sync any other gitignored
# .claude/* path (settings.json, settings.local.json, session-state files like
# compaction_log.txt/task_state.md/session_handoff.md/loop_*_state.md) -- an explicit human decision
# after reviewing a real repo's .gitignore: those other files are either sensitive local config or
# session-specific state that would be actively wrong to duplicate into a fresh worktree.
#
# Idempotency + non-overwrite guarantee, in one check: a skill directory that ALREADY EXISTS at its
# target path (even empty) is always skipped entirely, before any copy work starts for it. "Missing"
# means the directory does not exist at all. This is deliberately the ONLY check -- it makes re-running
# this script against the same worktree a safe no-op, and it means real tracked content that `git
# worktree add` already populated normally is never touched.
#
# Copy mechanics: each missing skill is copied (via `cp -R -p` -- portable across GNU/BSD, and `-p`
# preserves permission/mode bits including executable bits on helper scripts; no `-L`, so a symlink
# INSIDE a copied skill directory is preserved as a symlink rather than dereferenced, which matters
# because bin/scope-guard.py's existing symlink-resolution-before-bounds-check already denies a maker
# reading through such a symlink if it points outside the worktree) into a temp directory created
# WITHIN the destination worktree, then `mv`'d atomically into its final path -- so a kill mid-copy
# never leaves a half-written directory visible at the real target path.
#
# Named, accepted limitations (no fix planned -- do not "improve" these without a fresh design):
#   - ONE-TIME copy at worktree-creation time, not an ongoing sync. A file watcher, periodic re-sync,
#     manifest file, or git filter/sparse-checkout mechanism is explicitly out of scope. Skills modified
#     in the primary AFTER a worktree's sync ran will not propagate automatically.
#   - Worktrees created BEFORE this script existed do not retroactively benefit -- though a human can
#     manually re-run this script against an already-existing worktree to backfill it (this script is
#     safe to call standalone for exactly that purpose).
#   - No size caps, quotas, checksum validation, or locking/concurrency-race protection. None of these
#     are warranted for this narrow use case: small directories, one synchronous invocation per fresh
#     worktree.
set -euo pipefail

if [ "${1:-}" = "--selfcheck" ]; then
  fails=0
  t="$(mktemp -d)"

  # --- primary repo fixture, matching the real reproduced bug shape ---
  git init -q -b main "$t/primary" >/dev/null
  git -C "$t/primary" config user.email a@a; git -C "$t/primary" config user.name a

  # a nested (monorepo-style) gitignored skill, "alpha", with real non-trivial content plus a helper
  # script whose executable bit must survive the copy.
  mkdir -p "$t/primary/subproject/.claude/skills/alpha"
  cat > "$t/primary/subproject/.claude/skills/alpha/SKILL.md" <<'EOF'
---
name: alpha
description: fixture skill for sync-worktree-skills.sh selfcheck -- real, non-trivial content used to
  verify byte-identical copying through the actual copy code path (not a reimplementation of it).
---
# Alpha skill

This is real content, several lines long, so a truncated or corrupted copy would be detectable by a
plain byte-for-byte diff against the primary checkout's original file.

- line one of a checklist
- line two of a checklist
- line three of a checklist
EOF
  cat > "$t/primary/subproject/.claude/skills/alpha/helper.sh" <<'EOF'
#!/usr/bin/env bash
echo "alpha helper"
EOF
  chmod +x "$t/primary/subproject/.claude/skills/alpha/helper.sh"

  # a git-TRACKED (committed, NOT gitignored) skill "beta" that must propagate to the worktree the
  # normal way (via git worktree add itself) and must be left completely untouched by this script.
  mkdir -p "$t/primary/.claude/skills/beta"
  echo "tracked content" > "$t/primary/.claude/skills/beta/SKILL.md"

  cat > "$t/primary/.gitignore" <<'EOF'
**/.claude/skills/
EOF
  git -C "$t/primary" add -A
  # force-add beta despite the broad ignore pattern above -- mirrors how a real repo can have one
  # specific already-tracked skill committed even while a broader ignore pattern covers the directory.
  git -C "$t/primary" add -f .claude/skills/beta/SKILL.md
  git -C "$t/primary" commit -qm init >/dev/null

  git -C "$t/primary" worktree add -q -b feat "$t/wt" main

  # --- reproduce the bug precondition for real, before testing the fix ---
  [ ! -e "$t/wt/subproject/.claude/skills/alpha" ] \
    || { echo "FAIL: fixture broken -- alpha unexpectedly already present in the fresh worktree"; fails=1; }
  [ -f "$t/wt/.claude/skills/beta/SKILL.md" ] \
    || { echo "FAIL: fixture broken -- tracked beta missing from the fresh worktree"; fails=1; }

  # --- run the real fix ---
  if ! "$0" --primary "$t/primary" --worktree "$t/wt" >/dev/null 2>"$t/err1"; then
    echo "FAIL: first sync run exited nonzero: $(cat "$t/err1")"; fails=1
  fi

  # alpha now exists at the correct nested path, byte-identical, executable bit preserved.
  [ -f "$t/wt/subproject/.claude/skills/alpha/SKILL.md" ] || { echo "FAIL: alpha SKILL.md not synced"; fails=1; }
  diff -q "$t/primary/subproject/.claude/skills/alpha/SKILL.md" "$t/wt/subproject/.claude/skills/alpha/SKILL.md" >/dev/null \
    || { echo "FAIL: alpha SKILL.md content differs after sync"; fails=1; }
  diff -q "$t/primary/subproject/.claude/skills/alpha/helper.sh" "$t/wt/subproject/.claude/skills/alpha/helper.sh" >/dev/null \
    || { echo "FAIL: alpha helper.sh content differs after sync"; fails=1; }
  [ -x "$t/wt/subproject/.claude/skills/alpha/helper.sh" ] \
    || { echo "FAIL: alpha helper.sh executable bit not preserved"; fails=1; }

  # tracked beta (already present before the script ever ran) left completely untouched.
  [ "$(cat "$t/wt/.claude/skills/beta/SKILL.md")" = "tracked content" ] \
    || { echo "FAIL: tracked beta content changed"; fails=1; }

  # --- idempotency: a second run against the same worktree is a genuine no-op ---
  before_snapshot="$(cd "$t/wt" && find . -type f -not -path './.git/*' -exec sh -c 'echo "$1"; cat "$1"' _ {} \; | sort)"
  if ! "$0" --primary "$t/primary" --worktree "$t/wt" >/dev/null 2>"$t/err2"; then
    echo "FAIL: second (idempotent) sync run exited nonzero: $(cat "$t/err2")"; fails=1
  fi
  after_snapshot="$(cd "$t/wt" && find . -type f -not -path './.git/*' -exec sh -c 'echo "$1"; cat "$1"' _ {} \; | sort)"
  [ "$before_snapshot" = "$after_snapshot" ] || { echo "FAIL: second run changed the worktree (not idempotent)"; fails=1; }
  [ -z "$(find "$t/wt" -maxdepth 1 -name '.claude-skills-sync-tmp.*' 2>/dev/null)" ] \
    || { echo "FAIL: leftover tmp dir after sync"; fails=1; }

  # --- safe no-op: a primary checkout with NO .claude/skills anywhere ---
  git init -q -b main "$t/empty-primary" >/dev/null
  git -C "$t/empty-primary" config user.email a@a; git -C "$t/empty-primary" config user.name a
  echo x > "$t/empty-primary/f"; git -C "$t/empty-primary" add -A; git -C "$t/empty-primary" commit -qm init >/dev/null
  git -C "$t/empty-primary" worktree add -q -b feat "$t/empty-wt" main
  before_empty="$(find "$t/empty-wt" -type f -not -path '*/.git/*' | sort)"
  rc=0; "$0" --primary "$t/empty-primary" --worktree "$t/empty-wt" >/dev/null 2>"$t/err3" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: no-skills-anywhere case should exit 0, got $rc: $(cat "$t/err3")"; fails=1; }
  after_empty="$(find "$t/empty-wt" -type f -not -path '*/.git/*' | sort)"
  [ "$before_empty" = "$after_empty" ] || { echo "FAIL: no-skills-anywhere case changed the worktree"; fails=1; }

  # --- invalid inputs must fail loudly, not silently no-op ---
  rc=0; "$0" --primary "$t/does-not-exist" --worktree "$t/wt" >/dev/null 2>"$t/err4" || rc=$?
  { [ "$rc" != 0 ] && [ -s "$t/err4" ]; } || { echo "FAIL: nonexistent --primary should exit nonzero with a message (rc=$rc)"; fails=1; }

  rc=0; "$0" --primary "$t/primary" --worktree "$t/does-not-exist" >/dev/null 2>"$t/err5" || rc=$?
  { [ "$rc" != 0 ] && [ -s "$t/err5" ]; } || { echo "FAIL: nonexistent --worktree should exit nonzero with a message (rc=$rc)"; fails=1; }

  mkdir -p "$t/not-a-repo"
  rc=0; "$0" --primary "$t/not-a-repo" --worktree "$t/wt" >/dev/null 2>"$t/err6" || rc=$?
  { [ "$rc" != 0 ] && [ -s "$t/err6" ]; } || { echo "FAIL: non-git --primary should exit nonzero with a message (rc=$rc)"; fails=1; }

  touch "$t/afile"
  rc=0; "$0" --primary "$t/primary" --worktree "$t/afile" >/dev/null 2>"$t/err7" || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: --worktree pointing at a plain file should exit nonzero"; fails=1; }

  rm -rf "$t"
  [ "$fails" = 0 ] && echo ok
  exit "$fails"
fi

primary="" worktree=""
while [ $# -gt 0 ]; do
  case "$1" in
    --primary) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; primary="$2"; shift 2;;
    --worktree) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; worktree="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$primary" ] && [ -n "$worktree" ] || { echo "need --primary PATH --worktree PATH" >&2; exit 2; }

[ -d "$primary" ] || { echo "sync-worktree-skills: --primary is not a directory: $primary" >&2; exit 1; }
[ -d "$worktree" ] || { echo "sync-worktree-skills: --worktree is not a directory: $worktree" >&2; exit 1; }
git -C "$primary" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "sync-worktree-skills: --primary is not a git checkout: $primary" >&2; exit 1; }

primary="$(cd "$primary" && pwd)"
worktree="$(cd "$worktree" && pwd)"

# Copies one missing skill directory into the worktree via a temp-dir-then-atomic-mv two-step, so a
# kill mid-operation never leaves a half-written directory visible at the real target path. The temp
# dir is created WITHIN the destination worktree (per spec) and cleaned up via a function-local RETURN
# trap on every exit path out of this function, success or failure alike.
_sync_one_skill() {
  local skill_dir="$1" target="$2" name tmp
  name="$(basename "$skill_dir")"
  tmp="$(mktemp -d "$worktree/.claude-skills-sync-tmp.XXXXXX")" \
    || { echo "sync-worktree-skills: mktemp failed while syncing $skill_dir" >&2; return 1; }
  trap 'rm -rf "$tmp"' RETURN
  cp -R -p "$skill_dir" "$tmp/$name" \
    || { echo "sync-worktree-skills: failed to copy $skill_dir" >&2; return 1; }
  mkdir -p "$(dirname "$target")" \
    || { echo "sync-worktree-skills: failed to create $(dirname "$target")" >&2; return 1; }
  mv "$tmp/$name" "$target" \
    || { echo "sync-worktree-skills: failed to move synced copy into $target" >&2; return 1; }
}

fails=0
while IFS= read -r -d '' skills_dir; do
  # relparent is the path of this .claude/skills directory relative to $primary (e.g. ".claude/skills"
  # or "some-subproject/.claude/skills") -- computed by substring, not shell pattern-matching, so any
  # glob-special characters that happen to appear in $primary itself can't corrupt the result.
  relparent="${skills_dir:$((${#primary} + 1))}"
  while IFS= read -r -d '' skill_dir; do
    name="$(basename "$skill_dir")"
    target="$worktree/$relparent/$name"
    [ -e "$target" ] && continue   # already present (even empty) -- never touch it; the whole
                                    # idempotency + non-overwrite guarantee lives in this one check.
    if ! _sync_one_skill "$skill_dir" "$target"; then
      fails=1
    fi
  done < <(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d -print0)
done < <(find "$primary" -type d -path '*/.claude/skills' -print0)

exit "$fails"
