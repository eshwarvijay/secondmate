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
  # $1=repo $2=task_id -- prints exactly one of: present | clean | unknown: <reason>. Captures the
  # full producer output AND its own exit status SEPARATELY, then matches with a pipe-free bash
  # `case` -- never `producer | grep`. Reproduced directly (round 4): with enough worktrees that
  # `grep -qF` finds its match and exits early, `grep` SIGPIPE-kills the still-writing
  # `git worktree list` under this script's own `set -o pipefail`, and the pipeline's reported exit
  # status reflects the SIGPIPE-killed producer's nonzero exit, not grep's own successful match --
  # a genuinely PRESENT worktree was reported "clean". Same bug class this repo's own
  # merge-sequencer.sh (task git-coordinator) already hit and fixed the same way: eliminate the pipe
  # entirely rather than narrow the race window.
  #
  # A SECOND, DISTINCT bug (round 5): the round-4 fix's `|| true` on the capture line silently
  # swallowed a GENUINE producer failure (corrupt repo, permissions, any unrelated nonzero exit from
  # `git worktree list --porcelain`) and treated it identically to "producer succeeded, no match" --
  # still a false "clean", the exact same failure class already fixed for _check_herdr this same
  # round. Reproduced directly: a fake `git` that exits 128 for this exact call made this report
  # "clean" even though the check genuinely could not be performed. The producer's own exit status
  # is now captured and checked before ever inspecting its output -- a nonzero exit reports
  # "unknown", never "clean", matching _herdr_agent_state's own established convention.
  #
  # A THIRD, DISTINCT bug (round 6): the round-5 fix's `case "$out" in *"branch refs/heads/sm/$2"*)`
  # was a bare SUBSTRING match, not an exact-branch match -- porcelain's branch line for an unrelated
  # branch like sm/foo-bar is literally "branch refs/heads/sm/foo-bar", which CONTAINS
  # "branch refs/heads/sm/foo" as its own prefix, so task-id "foo" falsely matched an entirely
  # different worktree ("foo-bar"'s), reported [worktree] present. Reproduced directly with exactly
  # that fixture. Fixed by requiring a genuinely EXACT match against one whole line of the porcelain
  # output (each field is its own line) rather than a substring anywhere in the multi-line blob --
  # `_check_branch`/`_check_claim` were independently re-verified to NOT share this collision class
  # (`_check_branch` is a real `git rev-parse --verify` ref lookup, not text matching at all;
  # `_check_claim`'s `[$1]` pattern is bracket-delimited on both sides, so `[foo]` cannot match inside
  # `[foo-bar]`) -- confirmed by direct reproduction, not just by re-reading the code.
  local out rc=0
  out="$(git -C "$1" worktree list --porcelain 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "unknown: git -C $1 worktree list --porcelain failed (rc=$rc) -- cannot confirm worktree state"
    return
  fi
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "branch refs/heads/sm/$2" ]; then
      echo "present"
      return
    fi
  done <<< "$out"
  echo "clean"
}

_check_branch() {
  # $1=repo $2=task_id -- does the local branch sm/<task_id> still exist (even with its worktree already removed)?
  git -C "$1" rev-parse --verify -q "refs/heads/sm/$2" >/dev/null 2>&1
}

_herdr_agent_state() {
  # $1=agent name -- prints exactly one of: present | absent | unknown: <reason>
  # A nonzero exit alone does NOT mean "genuinely doesn't exist" -- reproduced directly with a fake
  # herdr that exits nonzero for an unrelated reason ("daemon unavailable") for ANY agent name, which
  # the earlier version silently reported as "clean" (herdr's own call failing was conflated with the
  # agent being confirmed absent). The real, confirmed-absent shape (verified directly against a real
  # herdr 0.8.0 installation): exit 1, and a JSON error object on stderr with code "agent_not_found".
  # ONLY that exact confirmed shape counts as "absent" -- any other nonzero exit, any other/missing
  # error code, or unparseable output is ambiguous and must report "unknown", never a false "absent".
  local out rc=0
  out="$(herdr agent get "$1" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "present"
    return
  fi
  local code
  code="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("error", {}).get("code", ""))
except Exception:
    print("")
' 2>/dev/null)"
  if [ "$code" = "agent_not_found" ]; then
    echo "absent"
  else
    echo "unknown: herdr agent get $1 failed unexpectedly (rc=$rc, not a confirmed agent_not_found): $out"
  fi
}

_check_herdr() {
  # $1=task_id -- prints exactly one of: clean | present | unknown: <reason>. "clean" only when BOTH
  # possible maker agent names are CONFIRMED absent (never merely "the call didn't return success").
  command -v herdr >/dev/null 2>&1 || { echo "unknown: herdr not found in PATH"; return; }
  [ "${HERDR_ENV:-}" = "1" ] || { echo "unknown: HERDR_ENV is not 1 (headless run -- cannot check)"; return; }

  local s1 s2
  s1="$(_herdr_agent_state "sm-$1")"
  s2="$(_herdr_agent_state "sm-pi-$1")"

  if [ "$s1" = "present" ] || [ "$s2" = "present" ]; then
    echo "present"
  elif [ "$s1" = "absent" ] && [ "$s2" = "absent" ]; then
    echo "clean"
  elif [ "$s1" != "absent" ]; then
    echo "$s1"
  else
    echo "$s2"
  fi
}

_check_claim() {
  # $1=task_id -- prints exactly one of: present | clean | unknown: <reason>. Delegates ledger-path
  # resolution entirely to claim-ledger.py itself (no path guessing here). Same pipe-free fix as
  # _check_worktree above (was previously `producer | grep -qF`, the identical SIGPIPE-under-pipefail
  # race) AND the same round-5 fix for a genuine producer failure: a nonzero exit from
  # `claim-ledger.py status` itself (e.g. python3 missing, the script crashing) must report
  # "unknown", never be silently treated as "no matching claim" (clean).
  local out rc=0
  out="$(python3 "$SCRIPT_DIR/claim-ledger.py" status 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "unknown: claim-ledger.py status failed (rc=$rc) -- cannot confirm claim state"
    return
  fi
  case "$out" in
    *"[$1]"*) echo "present";;
    *) echo "clean";;
  esac
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
  # The fixture's "not this one" branch emits the REAL confirmed-absent shape verified directly against
  # a real herdr 0.8.0 install: exit 1, a JSON error object on STDERR with code "agent_not_found" -- so
  # a task-id whose agent names don't match "sm-still-here" resolves to genuinely "absent", not merely
  # "the call failed" (see Test 9 below for the case where the call fails for an UNRELATED reason).
  fake_bin2="$t/fakebin-herdr"; mkdir -p "$fake_bin2"
  cat > "$fake_bin2/herdr" <<'HERDR_EOF'
#!/usr/bin/env bash
if [ "$1" = "agent" ] && [ "$2" = "get" ] && [ "$3" = "sm-still-here" ]; then
  echo '{"name":"sm-still-here"}'; exit 0
fi
echo "{\"error\":{\"code\":\"agent_not_found\",\"message\":\"agent target $3 not found\"}}" >&2
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

  # ---- Test 9: herdr's own call fails for an UNRELATED reason (a daemon/connectivity error, not a
  # confirmed "agent_not_found") -> must report [herdr] unknown, and must NEVER report [herdr] clean.
  # The earlier version conflated "the call failed" with "confirmed absent" and reported this exact
  # case as clean. ----
  fake_bin3="$t/fakebin-herdrfail"; mkdir -p "$fake_bin3"
  cat > "$fake_bin3/herdr" <<'HERDR_EOF'
#!/usr/bin/env bash
echo '{"error":{"code":"daemon_unavailable","message":"daemon unavailable"}}' >&2
exit 2
HERDR_EOF
  chmod +x "$fake_bin3/herdr"
  rc=0; out="$(PATH="$fake_bin3:$PATH" SM_CLAIM_LEDGER="$t/claims-empty4.jsonl" HERDR_ENV=1 "$0" --task-id herdr-fails --repo "$t/proj" 2>&1)" || rc=$?
  echo "$out" | grep -qi "\[herdr\].*unknown" || { echo "FAIL: an unrelated herdr call failure must report [herdr] unknown: $out"; fails=1; }
  echo "$out" | grep -qi "\[herdr\].*clean" && { echo "FAIL: an unrelated herdr call failure must NEVER report [herdr] clean (false clean): $out"; fails=1; }

  # ---- Test 10: real SIGPIPE-under-pipefail race in _check_worktree (and _check_claim, identical
  # shape) -- a `producer | grep -qF` pipe where grep finds an early match and exits, SIGPIPE-killing
  # the still-writing producer, made the pipeline's reported exit status reflect the SIGPIPE-killed
  # producer's nonzero exit under this script's own `set -o pipefail`, not grep's own successful match
  # -- silently reporting a genuinely PRESENT worktree/claim as "clean". A fake `git` (worktree case)
  # emits the real matching line early, then a large (~5MB) payload after it, so the still-writing
  # producer is reliably still mid-write when grep's early exit closes the pipe; a synthetic
  # claim-ledger with the real matching entry sorted first (by task-id) followed by 5000 filler
  # entries does the same for the claim case. Must actually fail before the pipe-free fix and pass
  # after -- not just asserting the happy path. ----
  fake_git_dir="$t/fake-git-bin"; mkdir -p "$fake_git_dir"
  real_git_path="$(command -v git)"
  cat > "$fake_git_dir/git" <<GITEOF
#!/usr/bin/env bash
real_git="$real_git_path"
if [[ "\$*" == *"worktree list --porcelain"* ]]; then
  echo "worktree /race/target"
  echo "HEAD 1111111111111111111111111111111111111111"
  echo "branch refs/heads/sm/race-target"
  echo
  python3 -c "print('x' * 5000000)"
  exit \$?
fi
exec "\$real_git" "\$@"
GITEOF
  chmod +x "$fake_git_dir/git"
  rc=0; out="$(PATH="$fake_git_dir:$PATH" SM_CLAIM_LEDGER="$t/claims-race-wt.jsonl" HERDR_ENV="" "$0" --task-id race-target --repo "$t/proj" 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: a genuinely present worktree (large-output SIGPIPE-race fixture) must report nonzero, not a false clean: $out"; fails=1; }
  echo "$out" | grep -qi "worktree.*present" || { echo "FAIL: expected worktree flagged present despite the large-output SIGPIPE race: $out"; fails=1; }

  claim_race_ledger="$t/claims-race-big.jsonl"
  python3 - "$claim_race_ledger" <<'EOF'
import json, secrets, time, sys
path = sys.argv[1]
with open(path, 'w') as f:
    f.write(json.dumps({"ev": "claimed", "task_id": "aaa-race-target", "owner": "tester",
                         "token": secrets.token_hex(16), "ts": time.strftime("%Y-%m-%dT%H:%M:%S")}) + "\n")
    for i in range(5000):
        f.write(json.dumps({"ev": "claimed", "task_id": "zzz-filler-%05d" % i, "owner": "tester",
                             "token": secrets.token_hex(16), "ts": time.strftime("%Y-%m-%dT%H:%M:%S")}) + "\n")
EOF
  rc=0; out="$(SM_CLAIM_LEDGER="$claim_race_ledger" HERDR_ENV="" "$0" --task-id aaa-race-target --repo "$t/proj" 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: a genuinely present claim (large-output SIGPIPE-race fixture) must report nonzero, not a false clean: $out"; fails=1; }
  echo "$out" | grep -qi "claim.*present" || { echo "FAIL: expected claim flagged present despite the large-output SIGPIPE race: $out"; fails=1; }

  # ---- Test 11: git's own call fails for an UNRELATED reason (round 5) -- `git worktree list
  # --porcelain` exiting 128 (e.g. a corrupt repo, permissions issue) is NOT "no matching worktree" --
  # must report [worktree] unknown, and must NEVER report [worktree] clean. The round-4 fix's
  # `|| true` on the output-capture line silently swallowed exactly this case. ----
  fake_git_dir2="$t/fake-git-fail"; mkdir -p "$fake_git_dir2"
  real_git_path2="$(command -v git)"
  cat > "$fake_git_dir2/git" <<GITFAILEOF
#!/usr/bin/env bash
real_git="$real_git_path2"
if [[ "\$*" == *"worktree list --porcelain"* ]]; then
  echo "fatal: simulated corrupt repository" >&2
  exit 128
fi
exec "\$real_git" "\$@"
GITFAILEOF
  chmod +x "$fake_git_dir2/git"
  rc=0; out="$(PATH="$fake_git_dir2:$PATH" SM_CLAIM_LEDGER="$t/claims-empty5.jsonl" HERDR_ENV="" "$0" --task-id git-fails --repo "$t/proj" 2>&1)" || rc=$?
  echo "$out" | grep -qi "\[worktree\].*unknown" || { echo "FAIL: a genuine git worktree-list failure must report [worktree] unknown: $out"; fails=1; }
  echo "$out" | grep -qi "\[worktree\].*clean" && { echo "FAIL: a genuine git worktree-list failure must NEVER report [worktree] clean (false clean): $out"; fails=1; }
  [ "$rc" = 0 ] || { echo "FAIL: an 'unknown' worktree check alone (nothing else present) must not force a nonzero exit: $rc: $out"; fails=1; }

  # ---- Test 12: claim-ledger.py's own call fails for an UNRELATED reason (round 5) -- python3
  # crashing/missing is NOT "no matching claim" -- must report [claim] unknown, must NEVER report
  # [claim] clean. Same false-clean failure class as Test 11, for the other producer|grep-shaped
  # check this round's fix targets. ----
  fake_bin5="$t/fakebin-pyfail"; mkdir -p "$fake_bin5"
  real_python_path="$(command -v python3)"
  cat > "$fake_bin5/python3" <<PYFAILEOF
#!/usr/bin/env bash
real_python="$real_python_path"
if [[ "\$*" == *"claim-ledger.py status"* ]]; then
  echo "simulated claim-ledger.py crash" >&2
  exit 3
fi
exec "\$real_python" "\$@"
PYFAILEOF
  chmod +x "$fake_bin5/python3"
  rc=0; out="$(PATH="$fake_bin5:$PATH" SM_CLAIM_LEDGER="$t/claims-empty6.jsonl" HERDR_ENV="" "$0" --task-id claim-py-fails --repo "$t/proj" 2>&1)" || rc=$?
  echo "$out" | grep -qi "\[claim\].*unknown" || { echo "FAIL: a genuine claim-ledger.py status failure must report [claim] unknown: $out"; fails=1; }
  echo "$out" | grep -qi "\[claim\].*clean" && { echo "FAIL: a genuine claim-ledger.py status failure must NEVER report [claim] clean (false clean): $out"; fails=1; }
  [ "$rc" = 0 ] || { echo "FAIL: an 'unknown' claim check alone (nothing else present) must not force a nonzero exit: $rc: $out"; fails=1; }

  # ---- Test 13: _check_worktree's exact-branch-match fix (round 6) -- an UNRELATED worktree whose
  # branch name has the target task-id as a proper PREFIX (sm/foo-bar vs task-id foo) must NOT be
  # mistaken for the target's own worktree. porcelain's branch line for the unrelated branch is
  # literally "branch refs/heads/sm/foo-bar", which CONTAINS "branch refs/heads/sm/foo" as a
  # substring -- the round-5 bare `*substring*` match falsely reported [worktree] present for this
  # exact fixture. Also confirms the exact-match case (the target's OWN worktree, e.g. sm/foo itself)
  # still correctly reports present -- the fix must not just start under-matching instead. ----
  git -C "$t/proj" worktree add -q -b sm/prefix-collision-bar "$t/wt-prefix-collision-bar" main
  rc=0; out="$(SM_CLAIM_LEDGER="$t/claims-empty7.jsonl" HERDR_ENV="" "$0" --task-id prefix-collision --repo "$t/proj" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: an unrelated worktree whose branch has the task-id as a proper prefix must not falsely report present: $rc: $out"; fails=1; }
  echo "$out" | grep -qi "\[worktree\].*clean" || { echo "FAIL: expected [worktree] clean for the prefix-collision fixture (task-id 'prefix-collision' vs only 'sm/prefix-collision-bar' present): $out"; fails=1; }

  git -C "$t/proj" worktree add -q -b sm/prefix-collision "$t/wt-prefix-collision-exact" main
  rc=0; out="$(SM_CLAIM_LEDGER="$t/claims-empty8.jsonl" HERDR_ENV="" "$0" --task-id prefix-collision --repo "$t/proj" 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "FAIL: the task-id's OWN exact-match worktree must still report present (and nonzero) once it also exists: $rc: $out"; fails=1; }
  echo "$out" | grep -qi "\[worktree\].*present" || { echo "FAIL: expected [worktree] present once the exact-match worktree (sm/prefix-collision) also exists: $out"; fails=1; }

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
any_unknown=0

# worktree, herdr, and claim can each report a real "unknown" (the check itself couldn't be
# performed) alongside present/clean; only "present" ever sets dirty, matching _herdr_agent_state's
# own established convention -- "unknown" is reported honestly but never forces a false "incomplete"
# on its own (a headless run with no herdr, or a transiently-unreadable producer, must not
# permanently block an otherwise-clean teardown from reporting success). _check_branch stays a plain
# boolean -- it's a single unpiped `git rev-parse --verify`, not one of the two producer|grep-shaped
# checks this round's fix targets.
wt_state="$(_check_worktree "$repo" "$task_id")"
[ "$wt_state" = "present" ] && dirty=1
case "$wt_state" in unknown*) any_unknown=1;; esac

if _check_branch "$repo" "$task_id"; then br_state="present"; dirty=1; else br_state="clean"; fi

herdr_state="$(_check_herdr "$task_id")"
[ "$herdr_state" = "present" ] && dirty=1
case "$herdr_state" in unknown*) any_unknown=1;; esac

claim_state="$(_check_claim "$task_id")"
[ "$claim_state" = "present" ] && dirty=1
case "$claim_state" in unknown*) any_unknown=1;; esac

echo "[worktree] $wt_state"
echo "[branch]   $br_state"
echo "[herdr]    $herdr_state"
echo "[claim]    $claim_state"

if [ "$dirty" = 1 ]; then
  echo "TEARDOWN: incomplete (see above) -- advisory only; decide whether to clean up manually"
  exit 1
elif [ "$any_unknown" = 1 ]; then
  echo "TEARDOWN: clean, but some state(s) could not be verified (see above) -- advisory only"
  exit 0
else
  echo "TEARDOWN: clean"
  exit 0
fi
