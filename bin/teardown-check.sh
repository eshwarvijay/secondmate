#!/usr/bin/env bash
# teardown-check.sh -- advisory scan for leftover per-task state after a supervisor believes a task's
# teardown (SKILL.md step 9) is complete. Checks 4 independent things a leaked task-id could still
# occupy: the git worktree, the git branch sm/<id>, a herdr pane/agent, and an open claim-ledger.py entry.
#
#   teardown-check.sh --task-id ID [--repo PATH]
#   teardown-check.sh --selfcheck
#
# Advisory only: a nonzero exit signals "something is still around", never a hard failure the caller
# must treat as fatal -- the supervisor (a prose-synthesizing loop, not a `set -e` shell script) decides
# what to do with the signal. Degrades gracefully when herdr/HERDR_ENV isn't available (this repo also
# runs fully headless via new-worktree.sh): that case is reported as its own "unknown" condition, never
# a false "clean" -- but "unknown" alone (nothing else present) still allows a clean exit 0, or every
# headless-only task would report "incomplete" forever.
#
# --task-id charset/length discipline mirrors claim-ledger.py's _TASK_ID_RE ([A-Za-z0-9_-], 1-128 chars)
# -- bash can't import that Python regex, so it's re-derived here as a `case` pattern, same pattern
# merge-sequencer.sh already uses for its own --branch charset check (different charset: no '/').
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_check_worktree() {
  # $1=repo $2=task_id -- is there a linked worktree whose branch is sm/<task_id>?
  git -C "$1" worktree list --porcelain 2>/dev/null | grep -qF "branch refs/heads/sm/$2"
}

_check_branch() {
  # $1=repo $2=task_id -- does the local branch sm/<task_id> still exist (even with its worktree already removed)?
  git -C "$1" rev-parse --verify -q "refs/heads/sm/$2" >/dev/null 2>&1
}

_check_herdr() {
  # $1=task_id -- prints exactly one of: clean | present | unknown: <reason>
  command -v herdr >/dev/null 2>&1 || { echo "unknown: herdr not found in PATH"; return; }
  [ "${HERDR_ENV:-}" = "1" ] || { echo "unknown: HERDR_ENV is not 1 (headless run -- cannot check)"; return; }
  if herdr agent get "sm-$1" >/dev/null 2>&1 || herdr agent get "sm-pi-$1" >/dev/null 2>&1; then
    echo "present"
  else
    echo "clean"
  fi
}

_check_claim() {
  # $1=task_id -- delegates ledger-path resolution entirely to claim-ledger.py itself (no path guessing here).
  python3 "$SCRIPT_DIR/claim-ledger.py" status 2>/dev/null | grep -qF "[$1]"
}

if [ "${1:-}" = "--selfcheck" ]; then
  t="$(mktemp -d)"; fails=0
  git init -q -b main "$t/proj" >/dev/null
  git -C "$t/proj" config user.email a@a; git -C "$t/proj" config user.name a
  echo x > "$t/proj/f"; git -C "$t/proj" add -A; git -C "$t/proj" commit -qm init

  # ---- Test 1: fully clean (no worktree, no branch, no claim, herdr unset) -> exit 0, "clean" reported ----
  rc=0; out="$(SM_CLAIM_LEDGER="$t/claims.jsonl" HERDR_ENV="" "$0" --task-id fully-clean --repo "$t/proj" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: fully-clean expected exit 0, got $rc: $out"; fails=1; }
  echo "$out" | grep -qi "clean" || { echo "FAIL: expected a clean report: $out"; fails=1; }

  # ---- Test 2: leftover worktree + branch -> exit nonzero, worktree flagged present ----
  git -C "$t/proj" worktree add -q -b sm/leftover-wt "$t/wt-leftover" main
  rc=0; out="$(SM_CLAIM_LEDGER="$t/claims.jsonl" HERDR_ENV="" "$0" --task-id leftover-wt --repo "$t/proj" 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: leftover worktree should report nonzero: $out"; fails=1; }
  echo "$out" | grep -qi "worktree.*present" || { echo "FAIL: expected worktree flagged present: $out"; fails=1; }
  git -C "$t/proj" worktree remove --force "$t/wt-leftover"

  # ---- Test 3: leftover branch only (worktree already removed) -> exit nonzero, branch present, worktree clean ----
  rc=0; out="$(SM_CLAIM_LEDGER="$t/claims.jsonl" HERDR_ENV="" "$0" --task-id leftover-wt --repo "$t/proj" 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: leftover branch (worktree already removed) should still report nonzero: $out"; fails=1; }
  echo "$out" | grep -qi "branch.*present" || { echo "FAIL: expected branch flagged present: $out"; fails=1; }
  echo "$out" | grep -qi "worktree.*clean" || { echo "FAIL: expected worktree flagged clean once removed: $out"; fails=1; }
  git -C "$t/proj" branch -D sm/leftover-wt >/dev/null

  # ---- Test 4: leftover claim-ledger entry -> exit nonzero, claim flagged present ----
  SM_CLAIM_LEDGER="$t/claims.jsonl" python3 "$SCRIPT_DIR/claim-ledger.py" claim --task-id claimed-task --owner tester >/dev/null
  rc=0; out="$(SM_CLAIM_LEDGER="$t/claims.jsonl" HERDR_ENV="" "$0" --task-id claimed-task --repo "$t/proj" 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: leftover claim should report nonzero: $out"; fails=1; }
  echo "$out" | grep -qi "claim.*present" || { echo "FAIL: expected claim flagged present: $out"; fails=1; }

  # ---- Test 5: HERDR_ENV=1 but herdr not installed -> herdr reports 'unknown', but nothing else is
  # present -> still a clean (exit 0) result, just qualified -- 'unknown' must never silently show as
  # a plain 'clean' herdr line, but it also must not permanently block headless-only callers. ----
  fake_bin="$t/fakebin-none"; mkdir -p "$fake_bin"
  # symlink in just what the script itself needs (git, python3) so herdr's own real directory can be
  # excluded from PATH entirely -- prepending an empty dir isn't enough, since a real herdr binary may
  # already sit in a later PATH entry the test can't otherwise avoid inheriting.
  ln -s "$(command -v git)" "$fake_bin/git"
  ln -s "$(command -v python3)" "$fake_bin/python3"
  rc=0; out="$(PATH="$fake_bin:/usr/bin:/bin" SM_CLAIM_LEDGER="$t/claims-empty.jsonl" HERDR_ENV=1 "$0" --task-id no-herdr-bin --repo "$t/proj" 2>&1)" || rc=$?
  echo "$out" | grep -qi "unknown" || { echo "FAIL: expected an 'unknown' herdr report when herdr isn't installed: $out"; fails=1; }
  [ "$rc" = 0 ] || { echo "FAIL: an 'unknown' herdr check alone (nothing else present) must not force a nonzero exit: $rc: $out"; fails=1; }

  # ---- Test 6: HERDR_ENV=1, herdr installed and reports the agent still exists -> present, nonzero ----
  fake_bin2="$t/fakebin-herdr"; mkdir -p "$fake_bin2"
  cat > "$fake_bin2/herdr" <<'HERDR_EOF'
#!/usr/bin/env bash
if [ "$1" = "agent" ] && [ "$2" = "get" ] && [ "$3" = "sm-still-here" ]; then
  echo '{"name":"sm-still-here"}'; exit 0
fi
exit 1
HERDR_EOF
  chmod +x "$fake_bin2/herdr"
  rc=0; out="$(PATH="$fake_bin2:$PATH" SM_CLAIM_LEDGER="$t/claims-empty2.jsonl" HERDR_ENV=1 "$0" --task-id still-here --repo "$t/proj" 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: a still-present herdr agent should report nonzero: $out"; fails=1; }
  echo "$out" | grep -qi "herdr.*present" || { echo "FAIL: expected herdr flagged present: $out"; fails=1; }

  # ---- Test 7: HERDR_ENV=1, herdr installed, agent genuinely gone -> herdr reports clean, exit 0 ----
  rc=0; out="$(PATH="$fake_bin2:$PATH" SM_CLAIM_LEDGER="$t/claims-empty3.jsonl" HERDR_ENV=1 "$0" --task-id truly-gone --repo "$t/proj" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: a genuinely absent herdr agent (herdr installed and reachable) should allow a clean exit: $rc: $out"; fails=1; }
  echo "$out" | grep -qi "herdr.*clean" || { echo "FAIL: expected herdr flagged clean: $out"; fails=1; }

  # ---- Test 8: --task-id charset/length validation ----
  for bad in "" "../etc" "a/b" "bad id" "$(python3 -c 'print("a"*129)')"; do
    rc=0; "$0" --task-id "$bad" --repo "$t/proj" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || { echo "FAIL: invalid --task-id '$bad' should exit 2, got $rc"; fails=1; }
  done

  rm -rf "$t"; [ "$fails" = 0 ] && echo ok; exit "$fails"
fi

task_id="" repo="."
while [ $# -gt 0 ]; do case "$1" in
  --task-id) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; task_id="$2"; shift 2;;
  --repo) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; repo="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$task_id" ] || { echo "need --task-id ID" >&2; exit 2; }
case "$task_id" in
  *[!A-Za-z0-9_-]*) echo "invalid --task-id: $task_id (allowed charset: [A-Za-z0-9_-])" >&2; exit 2;;
esac
[ "${#task_id}" -le 128 ] || { echo "invalid --task-id: $task_id (too long, max 128 chars)" >&2; exit 2; }

git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "--repo $repo is not a git working tree" >&2; exit 2; }

dirty=0

if _check_worktree "$repo" "$task_id"; then wt_state="present"; dirty=1; else wt_state="clean"; fi
if _check_branch "$repo" "$task_id"; then br_state="present"; dirty=1; else br_state="clean"; fi
herdr_state="$(_check_herdr "$task_id")"
[ "$herdr_state" = "present" ] && dirty=1
if _check_claim "$task_id"; then claim_state="present"; dirty=1; else claim_state="clean"; fi

echo "[worktree] $wt_state"
echo "[branch]   $br_state"
echo "[herdr]    $herdr_state"
echo "[claim]    $claim_state"

if [ "$dirty" = 1 ]; then
  echo "TEARDOWN: incomplete (see above) -- advisory only; decide whether to clean up manually"
  exit 1
elif [ "$herdr_state" != "clean" ]; then
  echo "TEARDOWN: clean, but herdr state could not be verified (see above) -- advisory only"
  exit 0
else
  echo "TEARDOWN: clean"
  exit 0
fi
