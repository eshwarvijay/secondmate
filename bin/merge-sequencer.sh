#!/usr/bin/env bash
# merge-sequencer.sh -- serialize concurrent merges to main/base from multiple independent
# sub-agent-supervisors, each finishing their own task's maker/checker/gate loop in their own
# worktree/branch around the same time. Ensures each merge is validated FRESH right before it lands.
#
# The freshness guarantee comes entirely from re-invoking bin/verify-gate.sh (unmodified, called
# exactly as it already exists) INSIDE the lock, immediately before the actual git merge. verify-gate.sh's
# own `git rev-parse --verify "${base}^{commit}"` is executed at call time, which is already fresh for
# this repo's real topology: one local .git shared by the primary checkout and every worktree via
# `git worktree`. The lock's job is efficiency/ordering/clean-failure UX, not correctness.
#
#   merge-sequencer.sh --repo PATH --worktree PATH --branch NAME --base main --checked-sha SHA \
#     [--test CMD] [--message MSG] [--wait-timeout SECONDS]
#   merge-sequencer.sh --selfcheck
#
# Lock:   ${SM_LOOP_STATE:-<repo>/.secondmate}/merge-sequencer.lock (mkdir-based singleton; anchored to
#         --repo by DEFAULT, not to the calling process's own ambient CWD -- every invocation targeting the
#         same --repo must resolve to the same lock regardless of which worktree/directory it happens to be
#         run from (the real invocation pattern: a sub-agent-supervisor's natural CWD is its OWN worktree).
#         A different path from bin/caffeinate-guard.sh's own lock -- SM_CAFFEINATE_ROOT/guard.pid +
#         .start.lock -- by design.
# Ledger: ${SM_MERGE_LEDGER:-<repo>/audit/merge-ledger.jsonl} -- same --repo-anchoring rationale as the lock.
#         One JSONL record per ATTEMPT (durable, not ephemeral .secondmate/ state), matching
#         bin/log-round.sh's audit/metrics.jsonl precedent.
#
# Exit codes: 0 success | 1 gate refusal (verify-gate.sh REFUSE, or --branch does not resolve to the exact
#             reviewed --checked-sha -- BRANCH_MISMATCH) | 2 usage error / precondition failure (never
#             logged to the ledger -- includes $repo already having an in-progress merge or dirty state
#             this invocation did not create) | 3 real git merge conflict (from THIS invocation's own merge
#             attempt only) | 4 push failed (local merge already landed) | 5 lock timeout.
#
# Ledger reason_code is a CLOSED enum: SUCCESS | GATE_REFUSE | BRANCH_MISMATCH | MERGE_CONFLICT |
#             PUSH_FAILED | LOCK_TIMEOUT -- never freeform.
#
# Settled scope (do not re-litigate): no internal auto-retry, no rebase-in-place on refusal, no
# priority queue / fairness policy, no automatic stale-lock expiry/steal, single machine only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_GATE="$SCRIPT_DIR/verify-gate.sh"

# LOCK_DIR/LEDGER are resolved AFTER argument parsing (once --repo is known) and anchored to $repo by
# default -- see the comment above _acquire_lock's first call site for why: resolving these relative to
# the calling process's own ambient CWD (as an earlier revision did) would let two sub-agent-supervisors,
# each invoked from within their OWN worktree but targeting the SAME --repo, silently resolve to two
# different locks and never actually serialize against each other at all.
LOCK_HELD=0

_release_lock() {
  if [ "$LOCK_HELD" = 1 ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
}
# A plain `trap ... INT TERM` only runs the handler and then RESUMES the script (it does not, by
# itself, terminate the process) -- so INT/TERM must release the lock and then re-raise the signal
# against ourselves with the trap disarmed, to get the normal kill-by-signal termination behavior
# (and its conventional 128+n exit code) instead of silently continuing past a caught signal.
_on_signal() {
  local sig="$1"
  _release_lock
  trap - EXIT INT TERM
  kill -s "$sig" "$$"
}
trap '_release_lock' EXIT
trap '_on_signal INT' INT
trap '_on_signal TERM' TERM

# Bounded wait-then-retry acquire. No automatic stale-lock steal by design -- a lock held past
# --wait-timeout fails closed (LOCK_TIMEOUT); a human notices and removes a truly stuck lock manually.
_acquire_lock() {
  local timeout="$1"
  mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null || true
  local start=$SECONDS
  while true; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
      LOCK_HELD=1
      return 0
    fi
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      return 1
    fi
    sleep 0.2
  done
}

# Append one JSONL record for this attempt. reason_code is a CLOSED enum -- never freeform --
# so the ledger stays usable for automated triage later. Returns nonzero if the write itself failed
# (e.g. mkdir -p / the append redirect hit a non-directory in the way) -- callers must check this and
# warn loudly rather than silently reporting overall success with a missing audit record.
_append_ledger() {
  local reason_code="$1" merged_sha="${2:-}"
  mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true
  python3 - "$branch" "$checked_sha" "${pre_merge_base_sha:-}" "$reason_code" "$merged_sha" <<'EOF' >> "$LEDGER"
import json, sys, time
branch, checked_sha, pre_merge_base_sha, reason_code, merged_sha = sys.argv[1:6]
rec = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
    "branch": branch,
    "checked_sha": checked_sha,
    "pre_merge_base_sha": pre_merge_base_sha,
    "reason_code": reason_code,
}
if merged_sha:
    rec["merged_sha"] = merged_sha
print(json.dumps(rec))
EOF
}

# Thin wrapper every call site should use instead of _append_ledger directly: a ledger-write failure
# must never be silent. The merge/push outcome is real and already happened (or genuinely didn't) --
# this never changes the caller's own exit code, it only makes a lost audit record LOUD instead of
# invisible.
_append_ledger_or_warn() {
  local reason_code="$1" merged_sha="${2:-}"
  if ! _append_ledger "$reason_code" "$merged_sha"; then
    echo "WARNING: failed to append the '$reason_code' record to the merge ledger ($LEDGER) -- the durable audit-trail record was NOT written for this attempt. This does not affect the actual git/merge/push outcome reported above/below, but the ledger is now missing an entry for it." >&2
  fi
}

_usage() {
  cat >&2 <<'EOF'
usage: merge-sequencer.sh --repo PATH --worktree PATH --branch NAME --base REF --checked-sha SHA
                           [--test CMD] [--message MSG] [--wait-timeout SECONDS]
       merge-sequencer.sh --selfcheck
EOF
}

# ============================== --selfcheck ==============================
if [ "${1:-}" = "--selfcheck" ]; then
  fails=0
  t="$(mktemp -d)"
  trap 'rm -rf "$t"' EXIT

  MS="$SCRIPT_DIR/merge-sequencer.sh"
  ledger_default="$t/audit/merge-ledger.jsonl"
  lock_default="$t/state"
  export SM_LOOP_STATE="$lock_default"
  export SM_MERGE_LEDGER="$ledger_default"

  _ms() { bash "$MS" "$@"; }

  # ledger helper: count records matching branch+reason_code
  _ledger_count() {  # _ledger_count <branch> <reason_code>
    [ -f "$ledger_default" ] || { echo 0; return; }
    python3 -c '
import json, sys
branch, code = sys.argv[1], sys.argv[2]
n = 0
for line in open(sys.argv[3]):
    line = line.strip()
    if not line:
        continue
    r = json.loads(line)
    if r.get("branch") == branch and r.get("reason_code") == code:
        n += 1
print(n)
' "$1" "$2" "$ledger_default"
  }

  # setup_repo <suffix> -> prints "<origin_dir>|<primary_dir>"; both created under $t
  _setup_repo() {
    local n="$1"
    local origin="$t/origin-$n" primary="$t/primary-$n"
    git init -q --bare "$origin"
    git init -q -b main "$primary"
    git -C "$primary" config user.email t@t.com
    git -C "$primary" config user.name t
    echo "line1" > "$primary/file.txt"
    git -C "$primary" add -A
    git -C "$primary" commit -q -m init
    git -C "$primary" remote add origin "$origin"
    git -C "$primary" push -q -u origin main
    echo "$origin|$primary"
  }

  # ---- Test 1: clean successful merge + push ----
  IFS='|' read -r origin1 primary1 <<<"$(_setup_repo 1)"
  git -C "$primary1" worktree add -q "$t/wt1" -b sm/clean-success main
  echo "feature-a" >> "$t/wt1/file.txt"
  git -C "$t/wt1" commit -qam "feature a"
  sha1="$(git -C "$t/wt1" rev-parse HEAD)"
  main_before1="$(git -C "$primary1" rev-parse main)"
  out1="$(_ms --repo "$primary1" --worktree "$t/wt1" --branch sm/clean-success --base main --checked-sha "$sha1" --wait-timeout 5 2>&1)"
  rc1=$?
  [ "$rc1" -eq 0 ] || { echo "FAIL: clean success expected rc=0, got $rc1: $out1"; fails=1; }
  main_after1="$(git -C "$primary1" rev-parse main)"
  [ "$main_after1" != "$main_before1" ] || { echo "FAIL: clean success did not advance main"; fails=1; }
  origin_sha1="$(git --git-dir="$origin1" rev-parse main 2>/dev/null || echo "")"
  [ "$origin_sha1" = "$main_after1" ] || { echo "FAIL: origin not pushed to match primary main ($origin_sha1 != $main_after1)"; fails=1; }
  [ "$(_ledger_count sm/clean-success SUCCESS)" = "1" ] || { echo "FAIL: expected exactly one SUCCESS ledger record for sm/clean-success"; fails=1; }

  # ---- Test 2: verify-gate refusal (dirty worktree) leaves main untouched ----
  IFS='|' read -r origin2 primary2 <<<"$(_setup_repo 2)"
  git -C "$primary2" worktree add -q "$t/wt2" -b sm/gate-refuse main
  echo "feature-b" >> "$t/wt2/file.txt"
  git -C "$t/wt2" commit -qam "feature b"
  sha2="$(git -C "$t/wt2" rev-parse HEAD)"
  echo "uncommitted" >> "$t/wt2/file.txt"   # dirty tree -> verify-gate.sh must refuse
  main_before2="$(git -C "$primary2" rev-parse main)"
  out2="$(_ms --repo "$primary2" --worktree "$t/wt2" --branch sm/gate-refuse --base main --checked-sha "$sha2" --wait-timeout 5 2>&1)"
  rc2=$?
  [ "$rc2" -eq 1 ] || { echo "FAIL: gate refusal expected rc=1, got $rc2: $out2"; fails=1; }
  echo "$out2" | grep -q "REFUSE" || { echo "FAIL: gate refusal output missing verbatim REFUSE text"; fails=1; }
  main_after2="$(git -C "$primary2" rev-parse main)"
  [ "$main_after2" = "$main_before2" ] || { echo "FAIL: main was touched despite gate refusal"; fails=1; }
  [ "$(_ledger_count sm/gate-refuse GATE_REFUSE)" = "1" ] || { echo "FAIL: expected exactly one GATE_REFUSE ledger record"; fails=1; }

  # ---- Test 2b: verify-gate refusal (stale checked-sha) also leaves main untouched ----
  IFS='|' read -r origin2b primary2b <<<"$(_setup_repo 2b)"
  git -C "$primary2b" worktree add -q "$t/wt2b" -b sm/stale-sha main
  echo "feature-c" >> "$t/wt2b/file.txt"
  git -C "$t/wt2b" commit -qam "feature c round 1"
  stale_sha="$(git -C "$t/wt2b" rev-parse HEAD)"
  echo "feature-c-more" >> "$t/wt2b/file.txt"
  git -C "$t/wt2b" commit -qam "feature c round 2"   # head moved past the checked sha
  main_before2b="$(git -C "$primary2b" rev-parse main)"
  out2b="$(_ms --repo "$primary2b" --worktree "$t/wt2b" --branch sm/stale-sha --base main --checked-sha "$stale_sha" --wait-timeout 5 2>&1)"
  rc2b=$?
  [ "$rc2b" -eq 1 ] || { echo "FAIL: stale-sha refusal expected rc=1, got $rc2b: $out2b"; fails=1; }
  echo "$out2b" | grep -q "head moved since checker verdict" || { echo "FAIL: stale-sha refusal missing expected verify-gate reason"; fails=1; }
  main_after2b="$(git -C "$primary2b" rev-parse main)"
  [ "$main_after2b" = "$main_before2b" ] || { echo "FAIL: main was touched despite stale-sha refusal"; fails=1; }

  # ---- Test 3: real git merge conflict -> exit 3, primary left clean at its pre-attempt HEAD ----
  IFS='|' read -r origin3 primary3 <<<"$(_setup_repo 3)"
  git -C "$primary3" worktree add -q "$t/wt3" -b sm/conflict main
  echo "conflict-A" > "$t/wt3/file.txt"
  git -C "$t/wt3" commit -qam "A"
  sha3="$(git -C "$t/wt3" rev-parse HEAD)"
  echo "conflict-B" > "$primary3/file.txt"
  git -C "$primary3" commit -qam "B"
  git -C "$primary3" push -q origin main
  before3="$(git -C "$primary3" rev-parse HEAD)"
  out3="$(_ms --repo "$primary3" --worktree "$t/wt3" --branch sm/conflict --base main --checked-sha "$sha3" --wait-timeout 5 2>&1)"
  rc3=$?
  [ "$rc3" -eq 3 ] || { echo "FAIL: merge conflict expected rc=3, got $rc3: $out3"; fails=1; }
  after3="$(git -C "$primary3" rev-parse HEAD)"
  [ "$before3" = "$after3" ] || { echo "FAIL: primary HEAD moved despite merge conflict ($before3 -> $after3)"; fails=1; }
  [ -z "$(git -C "$primary3" status --porcelain)" ] || { echo "FAIL: primary left dirty after merge conflict (no abort?)"; fails=1; }
  [ ! -e "$primary3/.git/MERGE_HEAD" ] || { echo "FAIL: MERGE_HEAD still present after conflict (merge not aborted)"; fails=1; }
  [ "$(_ledger_count sm/conflict MERGE_CONFLICT)" = "1" ] || { echo "FAIL: expected exactly one MERGE_CONFLICT ledger record"; fails=1; }

  # ---- Test 4: two concurrent invocations against two different branches -- exactly one proceeds
  # while the other waits then succeeds; both end up sequentially, correctly merged, no corruption ----
  IFS='|' read -r origin4 primary4 <<<"$(_setup_repo 4)"
  git -C "$primary4" worktree add -q "$t/wt4a" -b sm/conc-a main
  git -C "$primary4" worktree add -q "$t/wt4b" -b sm/conc-b main
  # separate, non-overlapping files -- two independent inserts at the same position in the SAME file
  # is a genuine content conflict in git even when non-adjacent in intent, so keep this test isolated
  # to the concurrency question (does the lock sequence them correctly?), not merge-conflict mechanics.
  echo "conc-a-line" > "$t/wt4a/file-a.txt"
  git -C "$t/wt4a" add file-a.txt
  git -C "$t/wt4a" commit -qam "a"
  echo "conc-b-line" > "$t/wt4b/file-b.txt"
  git -C "$t/wt4b" add file-b.txt
  git -C "$t/wt4b" commit -qam "b"
  sha4a="$(git -C "$t/wt4a" rev-parse HEAD)"
  sha4b="$(git -C "$t/wt4b" rev-parse HEAD)"
  (
    SM_LOOP_STATE="$SM_LOOP_STATE" SM_MERGE_LEDGER="$SM_MERGE_LEDGER" bash "$MS" \
      --repo "$primary4" --worktree "$t/wt4a" --branch sm/conc-a --base main --checked-sha "$sha4a" \
      --wait-timeout 20 > "$t/out4a.log" 2>&1
    echo $? > "$t/rc4a"
  ) &
  pid4a=$!
  (
    SM_LOOP_STATE="$SM_LOOP_STATE" SM_MERGE_LEDGER="$SM_MERGE_LEDGER" bash "$MS" \
      --repo "$primary4" --worktree "$t/wt4b" --branch sm/conc-b --base main --checked-sha "$sha4b" \
      --wait-timeout 20 > "$t/out4b.log" 2>&1
    echo $? > "$t/rc4b"
  ) &
  pid4b=$!
  wait "$pid4a" "$pid4b"
  rc4a="$(cat "$t/rc4a")"; rc4b="$(cat "$t/rc4b")"
  [ "$rc4a" = 0 ] && [ "$rc4b" = 0 ] || { echo "FAIL: concurrent merges did not both succeed (rc_a=$rc4a rc_b=$rc4b)"; echo "out-a: $(cat "$t/out4a.log")"; echo "out-b: $(cat "$t/out4b.log")"; fails=1; }
  [ -f "$primary4/file-a.txt" ] && grep -q "conc-a-line" "$primary4/file-a.txt" || { echo "FAIL: concurrent merge lost sm/conc-a's change"; fails=1; }
  [ -f "$primary4/file-b.txt" ] && grep -q "conc-b-line" "$primary4/file-b.txt" || { echo "FAIL: concurrent merge lost sm/conc-b's change"; fails=1; }
  origin4_main="$(git --git-dir="$origin4" rev-parse main 2>/dev/null || echo "")"
  primary4_main="$(git -C "$primary4" rev-parse main)"
  [ "$origin4_main" = "$primary4_main" ] || { echo "FAIL: origin main diverged from primary main after concurrent merges"; fails=1; }
  [ "$(_ledger_count sm/conc-a SUCCESS)" = "1" ] || { echo "FAIL: expected one SUCCESS record for sm/conc-a"; fails=1; }
  [ "$(_ledger_count sm/conc-b SUCCESS)" = "1" ] || { echo "FAIL: expected one SUCCESS record for sm/conc-b"; fails=1; }

  # ---- Test 5: a held lock past --wait-timeout produces a clean LOCK_TIMEOUT failure ----
  IFS='|' read -r origin5 primary5 <<<"$(_setup_repo 5)"
  git -C "$primary5" worktree add -q "$t/wt5" -b sm/lock-timeout main
  echo "feature-e" >> "$t/wt5/file.txt"
  git -C "$t/wt5" commit -qam "feature e"
  sha5="$(git -C "$t/wt5" rev-parse HEAD)"
  held_lock_root="$t/state5"
  mkdir -p "$held_lock_root/merge-sequencer.lock"   # simulate a lock already held by someone else
  main_before5="$(git -C "$primary5" rev-parse main)"
  start5=$SECONDS
  out5="$(SM_LOOP_STATE="$held_lock_root" SM_MERGE_LEDGER="$t/ledger5.jsonl" bash "$MS" \
    --repo "$primary5" --worktree "$t/wt5" --branch sm/lock-timeout --base main --checked-sha "$sha5" --wait-timeout 2 2>&1)"
  rc5=$?
  elapsed5=$((SECONDS - start5))
  [ "$rc5" -eq 5 ] || { echo "FAIL: lock timeout expected rc=5, got $rc5: $out5"; fails=1; }
  [ "$elapsed5" -ge 2 ] || { echo "FAIL: lock timeout returned too fast (elapsed=${elapsed5}s, wanted >=2s)"; fails=1; }
  [ "$elapsed5" -le 8 ] || { echo "FAIL: lock timeout took implausibly long (elapsed=${elapsed5}s)"; fails=1; }
  main_after5="$(git -C "$primary5" rev-parse main)"
  [ "$main_after5" = "$main_before5" ] || { echo "FAIL: main was touched despite lock timeout"; fails=1; }
  [ -f "$t/ledger5.jsonl" ] && grep -q '"reason_code": *"LOCK_TIMEOUT"' "$t/ledger5.jsonl" 2>/dev/null || \
    { grep -q '"reason_code":\s*"LOCK_TIMEOUT"' "$t/ledger5.jsonl" 2>/dev/null || { echo "FAIL: expected a LOCK_TIMEOUT ledger record"; fails=1; }; }
  # the lock we pre-created should still be sitting there untouched (no steal)
  [ -d "$held_lock_root/merge-sequencer.lock" ] || { echo "FAIL: pre-existing held lock was removed (should never be stolen)"; fails=1; }

  # ---- Test 6: lock file path does not collide with bin/caffeinate-guard.sh's own lock path ----
  ms_lock_path_form='${SM_LOOP_STATE:-.secondmate}/merge-sequencer.lock'
  cg_pidfile_path_form='${SM_CAFFEINATE_ROOT:-~/.secondmate-caffeinate}/guard.pid'
  cg_claimfile_path_form='${SM_CAFFEINATE_ROOT:-~/.secondmate-caffeinate}/.start.lock'
  [ "$ms_lock_path_form" != "$cg_pidfile_path_form" ] || { echo "FAIL: merge-sequencer lock path collides with caffeinate-guard pidfile path"; fails=1; }
  [ "$ms_lock_path_form" != "$cg_claimfile_path_form" ] || { echo "FAIL: merge-sequencer lock path collides with caffeinate-guard claimfile path"; fails=1; }
  grep -q '\$root/guard\.pid' "$SCRIPT_DIR/caffeinate-guard.sh" || { echo "FAIL: could not confirm caffeinate-guard.sh's own pidfile path (drifted?)"; fails=1; }
  grep -q '\$root/\.start\.lock' "$SCRIPT_DIR/caffeinate-guard.sh" || { echo "FAIL: could not confirm caffeinate-guard.sh's own claimfile path (drifted?)"; fails=1; }

  # ---- Test 7: malformed/malicious --branch is rejected before touching anything (usage error, exit 2) ----
  IFS='|' read -r origin7 primary7 <<<"$(_setup_repo 7)"
  git -C "$primary7" worktree add -q "$t/wt7" -b sm/inject-target main
  echo "x" >> "$t/wt7/file.txt"
  git -C "$t/wt7" commit -qam c
  sha7="$(git -C "$t/wt7" rev-parse HEAD)"
  before_ledger_lines="$(wc -l < "$ledger_default" 2>/dev/null || echo 0)"
  rc7=0
  out7="$(_ms --repo "$primary7" --worktree "$t/wt7" --branch 'sm/evil;rm -rf /' --base main --checked-sha "$sha7" --wait-timeout 5 2>&1)" || rc7=$?
  [ "$rc7" -eq 2 ] || { echo "FAIL: malicious branch name should be rejected with exit 2, got $rc7"; fails=1; }
  after_ledger_lines="$(wc -l < "$ledger_default" 2>/dev/null || echo 0)"
  [ "$before_ledger_lines" = "$after_ledger_lines" ] || { echo "FAIL: a rejected (usage-error) call still wrote to the ledger"; fails=1; }

  # ---- Test 8: lock/ledger defaults are anchored to --repo, NOT to the calling process's own ambient
  # CWD. This is the realistic invocation pattern this script exists for: a sub-agent-supervisor's natural
  # CWD is its OWN worktree (every maker launched via herdr runs with CWD set to its own worktree), while
  # --repo is the one thing every concurrent caller actually shares. SM_LOOP_STATE/SM_MERGE_LEDGER are left
  # UNSET here (unlike every other test above) so the script must compute its own --repo-anchored default
  # -- an env-var override would mask the exact bug this test regression-guards.
  IFS='|' read -r origin8 primary8 <<<"$(_setup_repo 8)"
  git -C "$primary8" worktree add -q "$t/wt8" -b sm/cwd-anchor main
  echo "feature-h" >> "$t/wt8/file.txt"
  git -C "$t/wt8" commit -qam "feature h"
  sha8="$(git -C "$t/wt8" rev-parse HEAD)"
  other_cwd="$t/elsewhere8"
  mkdir -p "$other_cwd"
  default_lock8="$primary8/.secondmate/merge-sequencer.lock"
  default_ledger8="$primary8/audit/merge-ledger.jsonl"
  bogus_lock8="$other_cwd/.secondmate/merge-sequencer.lock"
  mkdir -p "$default_lock8"   # simulate a sibling merge already in flight, at the CORRECT --repo-anchored path
  main_before8="$(git -C "$primary8" rev-parse main)"
  out8="$(cd "$other_cwd" && unset SM_LOOP_STATE SM_MERGE_LEDGER && bash "$MS" \
    --repo "$primary8" --worktree "$t/wt8" --branch sm/cwd-anchor --base main --checked-sha "$sha8" \
    --wait-timeout 2 2>&1)"
  rc8=$?
  [ "$rc8" -eq 5 ] || { echo "FAIL: different-CWD invocation targeting the same --repo expected LOCK_TIMEOUT (rc=5), got $rc8: $out8"; fails=1; }
  main_after8="$(git -C "$primary8" rev-parse main)"
  [ "$main_after8" = "$main_before8" ] || { echo "FAIL: different-CWD invocation proceeded past a lock it should have shared (main was touched) -- lock is NOT anchored to --repo"; fails=1; }
  [ ! -d "$bogus_lock8" ] || { echo "FAIL: a separate lock dir was created relative to the calling process's CWD instead of --repo (the exact bug being regression-tested)"; fails=1; }
  [ -d "$default_lock8" ] || { echo "FAIL: the pre-existing --repo-anchored lock was removed (should never be stolen)"; fails=1; }
  grep -q '"reason_code": *"LOCK_TIMEOUT"' "$default_ledger8" 2>/dev/null || { echo "FAIL: expected a LOCK_TIMEOUT record in the --repo-anchored default ledger ($default_ledger8)"; fails=1; }
  rm -rf "$default_lock8"

  # ---- Test 9: --branch must resolve to EXACTLY --checked-sha, the commit verify-gate.sh actually
  # reviewed in --worktree. A reviewed 'good' worktree/SHA plus a completely different, never-reviewed
  # --branch string must be refused (BRANCH_MISMATCH), not silently merged instead of the reviewed commit.
  IFS='|' read -r origin9 primary9 <<<"$(_setup_repo 9)"
  git -C "$primary9" worktree add -q "$t/wt9-good" -b sm/good main
  echo "good-content" >> "$t/wt9-good/file.txt"
  git -C "$t/wt9-good" commit -qam "good"
  good_sha9="$(git -C "$t/wt9-good" rev-parse HEAD)"
  git -C "$primary9" worktree add -q "$t/wt9-evil" -b sm/evil main
  echo "evil-content" >> "$t/wt9-evil/file2.txt"
  git -C "$t/wt9-evil" add file2.txt
  git -C "$t/wt9-evil" commit -qam "evil (never reviewed)"
  main_before9="$(git -C "$primary9" rev-parse main)"
  out9="$(_ms --repo "$primary9" --worktree "$t/wt9-good" --branch sm/evil --base main --checked-sha "$good_sha9" --wait-timeout 5 2>&1)"
  rc9=$?
  [ "$rc9" -eq 1 ] || { echo "FAIL: branch/checked-sha mismatch expected rc=1, got $rc9: $out9"; fails=1; }
  echo "$out9" | grep -q "does not match --checked-sha" || { echo "FAIL: branch mismatch output missing expected explanation"; fails=1; }
  main_after9="$(git -C "$primary9" rev-parse main)"
  [ "$main_after9" = "$main_before9" ] || { echo "FAIL: main was touched despite branch/checked-sha mismatch"; fails=1; }
  [ ! -f "$primary9/file2.txt" ] || { echo "FAIL: unreviewed 'evil' branch content landed on main -- the exact bug being regression-tested"; fails=1; }
  [ "$(_ledger_count sm/evil BRANCH_MISMATCH)" = "1" ] || { echo "FAIL: expected exactly one BRANCH_MISMATCH ledger record for sm/evil"; fails=1; }

  # ---- Test 10: a PRE-EXISTING, unrelated in-progress conflicted merge on --repo (e.g. a human's own
  # unresolved conflict resolution) must be detected and refused BEFORE this invocation's own git merge
  # ever runs -- and 'git merge --abort' must NEVER be called against a conflict this invocation didn't
  # start, since that would destroy state that was never this script's to touch.
  IFS='|' read -r origin10 primary10 <<<"$(_setup_repo 10)"
  git -C "$primary10" worktree add -q "$t/wt10" -b sm/precond main
  echo "feature-j" >> "$t/wt10/file.txt"
  git -C "$t/wt10" commit -qam "feature j"
  sha10="$(git -C "$t/wt10" rev-parse HEAD)"
  # simulate a human's own pre-existing, unrelated, unresolved conflict directly on primary10 -- this
  # invocation must never touch it.
  git -C "$primary10" checkout -qb human-side main
  echo "human-conflict" > "$primary10/file.txt"
  git -C "$primary10" commit -qam "human side"
  git -C "$primary10" checkout -q main
  echo "main-conflict" > "$primary10/file.txt"
  git -C "$primary10" commit -qam "main side"
  git -C "$primary10" merge --no-ff human-side -m "human's in-progress merge" >/dev/null 2>&1 || true
  git -C "$primary10" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || { echo "FAIL: test setup did not produce a pre-existing MERGE_HEAD (fixture broken)"; fails=1; }
  merge_head_before10="$(git -C "$primary10" rev-parse MERGE_HEAD 2>/dev/null || echo "")"
  file_before10="$(cat "$primary10/file.txt" 2>/dev/null || echo "")"
  main_before10="$(git -C "$primary10" rev-parse main)"
  out10="$(_ms --repo "$primary10" --worktree "$t/wt10" --branch sm/precond --base main --checked-sha "$sha10" --wait-timeout 5 2>&1)"
  rc10=$?
  [ "$rc10" -eq 2 ] || { echo "FAIL: pre-existing unrelated conflict expected rc=2, got $rc10: $out10"; fails=1; }
  git -C "$primary10" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || { echo "FAIL: pre-existing MERGE_HEAD was destroyed -- the exact bug being regression-tested"; fails=1; }
  merge_head_after10="$(git -C "$primary10" rev-parse MERGE_HEAD 2>/dev/null || echo "")"
  [ "$merge_head_after10" = "$merge_head_before10" ] || { echo "FAIL: pre-existing MERGE_HEAD changed ($merge_head_before10 -> $merge_head_after10)"; fails=1; }
  file_after10="$(cat "$primary10/file.txt" 2>/dev/null || echo "")"
  [ "$file_after10" = "$file_before10" ] || { echo "FAIL: pre-existing conflict markers were altered (merge --abort ran against a conflict this invocation didn't start)"; fails=1; }
  main_after10="$(git -C "$primary10" rev-parse main)"
  [ "$main_after10" = "$main_before10" ] || { echo "FAIL: main moved despite refusing on a pre-existing unrelated conflict"; fails=1; }

  # ---- Test 11: the DEFAULT invocation (no --repo-anchored lock/ledger override, no .gitignore entry
  # for .secondmate/ at all) on a genuinely clean repo must succeed -- the script's OWN lock directory
  # must never trip its OWN round-3 dirty-repo guard. This deliberately exercises the real default path
  # every other test above avoids by setting SM_LOOP_STATE outside the repo.
  IFS='|' read -r origin11 primary11 <<<"$(_setup_repo 11)"
  git -C "$primary11" worktree add -q "$t/wt11" -b sm/default-clean main
  echo "feature-k" >> "$t/wt11/file.txt"
  git -C "$t/wt11" commit -qam "feature k"
  sha11="$(git -C "$t/wt11" rev-parse HEAD)"
  [ -f "$primary11/.gitignore" ] && grep -q secondmate "$primary11/.gitignore" && { echo "FAIL: test fixture unexpectedly ignores .secondmate/ -- would mask the real bug"; fails=1; }
  main_before11="$(git -C "$primary11" rev-parse main)"
  out11="$(unset SM_LOOP_STATE SM_MERGE_LEDGER; bash "$MS" --repo "$primary11" --worktree "$t/wt11" --branch sm/default-clean --base main --checked-sha "$sha11" --wait-timeout 5 2>&1)"
  rc11=$?
  [ "$rc11" -eq 0 ] || { echo "FAIL: default invocation on a genuinely clean repo (no .secondmate/ .gitignore entry) expected rc=0, got $rc11: $out11"; fails=1; }
  main_after11="$(git -C "$primary11" rev-parse main)"
  [ "$main_after11" != "$main_before11" ] || { echo "FAIL: default invocation did not advance main despite claimed success"; fails=1; }
  [ ! -d "$primary11/.secondmate/merge-sequencer.lock" ] || { echo "FAIL: default lock directory left behind after success"; fails=1; }
  [ -f "$primary11/audit/merge-ledger.jsonl" ] || { echo "FAIL: expected the default (--repo-anchored) ledger at $primary11/audit/merge-ledger.jsonl"; fails=1; }
  grep -q '"reason_code": *"SUCCESS"' "$primary11/audit/merge-ledger.jsonl" 2>/dev/null || { echo "FAIL: expected a SUCCESS record in the default ledger"; fails=1; }

  # ---- Test 12: a ledger-write failure (the default ledger's directory colliding with a tracked
  # regular FILE, not a directory) must NOT fail an otherwise-successful merge+push -- but must print a
  # clear WARNING to stderr naming the ledger path, never silently vanish.
  IFS='|' read -r origin12 primary12 <<<"$(_setup_repo 12)"
  git -C "$primary12" worktree add -q "$t/wt12" -b sm/ledger-fail main
  echo "feature-l" >> "$t/wt12/file.txt"
  git -C "$t/wt12" commit -qam "feature l"
  sha12="$(git -C "$t/wt12" rev-parse HEAD)"
  # 'audit' is a tracked regular FILE, not a directory -- mkdir -p "$repo/audit" (the ledger's parent)
  # can never succeed, so the ledger append must fail while the merge/push themselves are unaffected.
  echo "not a directory" > "$primary12/audit"
  git -C "$primary12" add audit
  git -C "$primary12" commit -qam "add audit file (collides with default ledger dir)"
  main_before12="$(git -C "$primary12" rev-parse main)"
  lock_root12="$t/state12"   # keep the lock isolated/explicit so this test exercises ONLY the ledger failure
  # SM_MERGE_LEDGER must be explicitly unset (not just left at the outer harness's own override) so the
  # script computes its own --repo-anchored default -- otherwise this would silently write to
  # ledger_default instead of exercising the actual bug. (No comments inside the $(...) below -- bash 3.2
  # mis-parses an apostrophe inside a comment nested in a multi-line command substitution.)
  out12="$(
    export SM_LOOP_STATE="$lock_root12"
    unset SM_MERGE_LEDGER
    bash "$MS" --repo "$primary12" --worktree "$t/wt12" --branch sm/ledger-fail --base main --checked-sha "$sha12" --wait-timeout 5 2>&1
  )"
  rc12=$?
  [ "$rc12" -eq 0 ] || { echo "FAIL: a ledger-write failure must not fail an otherwise-successful merge, got rc=$rc12: $out12"; fails=1; }
  main_after12="$(git -C "$primary12" rev-parse main)"
  [ "$main_after12" != "$main_before12" ] || { echo "FAIL: main did not advance despite the merge/push being unaffected by the ledger failure"; fails=1; }
  echo "$out12" | grep -qi "WARNING" || { echo "FAIL: expected a WARNING about the ledger-write failure, got: $out12"; fails=1; }
  echo "$out12" | grep -q "merge-ledger.jsonl" || { echo "FAIL: WARNING should name the ledger path, got: $out12"; fails=1; }

  rm -rf "$t"
  trap - EXIT
  [ "$fails" = 0 ] && echo ok
  exit "$fails"
fi

# ============================== argument parsing ==============================
repo="" worktree="" branch="" base="main" checked_sha="" test_cmd="" message="" wait_timeout=300
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; repo="$2"; shift 2;;
    --worktree) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; worktree="$2"; shift 2;;
    --branch) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; branch="$2"; shift 2;;
    --base) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; base="$2"; shift 2;;
    --checked-sha) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; checked_sha="$2"; shift 2;;
    --test) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; test_cmd="$2"; shift 2;;
    --message) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; message="$2"; shift 2;;
    --wait-timeout) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; wait_timeout="$2"; shift 2;;
    --selfcheck) shift;; # already handled above when it's $1; keep parser tolerant if it appears later
    -h|--help) _usage; exit 2;;
    *) echo "unknown arg: $1" >&2; _usage; exit 2;;
  esac
done

[ -n "$repo" ] || { echo "need --repo PATH" >&2; _usage; exit 2; }
[ -n "$worktree" ] || { echo "need --worktree PATH" >&2; _usage; exit 2; }
[ -n "$branch" ] || { echo "need --branch NAME" >&2; _usage; exit 2; }
[ -n "$checked_sha" ] || { echo "need --checked-sha SHA" >&2; _usage; exit 2; }
case "$wait_timeout" in ''|*[!0-9]*) echo "invalid --wait-timeout: $wait_timeout (want a non-negative integer)" >&2; exit 2;; esac

# Closes a real command-injection concern: reject anything that isn't a plain branch-name charset
# before it ever reaches an unquoted-adjacent git invocation.
case "$branch" in
  *[!a-zA-Z0-9_/-]*) echo "invalid --branch: $branch (allowed charset: [a-zA-Z0-9_/-])" >&2; exit 2;;
  '') echo "invalid --branch: empty" >&2; exit 2;;
esac

[ -d "$repo" ] || { echo "--repo $repo is not a directory" >&2; exit 2; }
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "--repo $repo is not a git working tree" >&2; exit 2; }
[ -d "$worktree" ] || { echo "--worktree $worktree is not a directory" >&2; exit 2; }

# The actual merge/push happens in $repo, so $repo must actually have $base checked out --
# otherwise the merge would silently land on whatever branch $repo happens to be on.
repo_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
if [ "$repo_branch" != "$base" ]; then
  echo "--repo $repo is checked out on '$repo_branch', not --base '$base' -- refusing (merge would land on the wrong branch)" >&2
  exit 2
fi

[ -n "$message" ] || message="Merge $branch"

# Anchored to $repo by default -- see header comment. Two callers pointing at the SAME --repo (however
# each one spells that path, and regardless of each one's own ambient CWD) resolve to the SAME lock and
# ledger, because mkdir/open operate on the OS-resolved location, not the literal string.
LOCK_DIR="${SM_LOOP_STATE:-$repo/.secondmate}/merge-sequencer.lock"
LEDGER="${SM_MERGE_LEDGER:-$repo/audit/merge-ledger.jsonl}"

# ============================== acquire lock ==============================
if ! _acquire_lock "$wait_timeout"; then
  # Best-effort, informational only -- no attempt was ever made, so this may be stale.
  pre_merge_base_sha="$(git -C "$repo" rev-parse --verify "${base}^{commit}" 2>/dev/null || echo "")"
  echo "ERROR: failed to acquire merge-sequencer lock ($LOCK_DIR) within ${wait_timeout}s -- another merge is in progress, or the lock is stuck. This is never auto-stolen; a human should investigate and remove it manually if stuck." >&2
  _append_ledger_or_warn LOCK_TIMEOUT ""
  exit 5
fi

# ============================== inside the lock: fresh gate, then merge, then push ==============================
# Freshly resolved right now, inside the lock, immediately before gating -- this (plus verify-gate.sh's
# own fresh rev-parse of $base) is the entire "re-verify right before merging" guarantee.
pre_merge_base_sha="$(git -C "$worktree" rev-parse --verify "${base}^{commit}" 2>/dev/null || echo "")"

gate_cmd=(bash "$VERIFY_GATE" --worktree "$worktree" --base "$base" --checked-sha "$checked_sha")
[ -n "$test_cmd" ] && gate_cmd+=(--test "$test_cmd")
gate_output="$("${gate_cmd[@]}" 2>&1)"
gate_rc=$?

if [ "$gate_rc" -ne 0 ]; then
  _release_lock
  printf '%s\n' "$gate_output" >&2
  _append_ledger_or_warn GATE_REFUSE ""
  exit 1
fi

# Bug A fix: verify-gate.sh only confirms --worktree's own HEAD matches --checked-sha -- it has no
# opinion on --branch at all. Without this check, --branch could be ANY string (a completely different,
# never-reviewed branch) and this script would happily merge that instead of the reviewed commit.
# --branch is the thing actually merged, so it must resolve to EXACTLY the reviewed commit.
branch_sha="$(git -C "$repo" rev-parse --verify "${branch}^{commit}" 2>/dev/null || echo "")"
if [ -z "$branch_sha" ] || [ "$branch_sha" != "$checked_sha" ]; then
  _release_lock
  echo "REFUSE: --branch '$branch' resolves to '${branch_sha:-<does not resolve>}', which does not match --checked-sha '$checked_sha' (the commit verify-gate.sh actually reviewed in --worktree '$worktree'). Refusing to merge a branch that was never verified as this exact commit." >&2
  _append_ledger_or_warn BRANCH_MISMATCH ""
  exit 1
fi

# Bug B fix: a bare 'git merge' failing does NOT always mean THIS invocation created a fresh
# conflict -- $repo may already have an unrelated, in-progress conflicted merge (e.g. a human's own
# unresolved conflict resolution) sitting there from before this invocation ever started. If so, git
# itself will refuse to even start our merge, and treating that identically to a fresh conflict would
# make us call `git merge --abort`, DESTROYING a conflict state that was never ours to touch. Detect
# and refuse BEFORE attempting our own merge -- never call --abort on a merge we didn't start.
if git -C "$repo" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  _release_lock
  echo "ERROR: $repo already has an in-progress merge (MERGE_HEAD present) that this invocation did not start -- refusing to touch it. A human must resolve or abort it directly in $repo before this can retry." >&2
  exit 2
fi
repo_dirty="$(git -C "$repo" status --porcelain -- . ":(exclude)$(basename "$(dirname "$LOCK_DIR")")" 2>/dev/null)"
if [ -n "$repo_dirty" ]; then
  _release_lock
  echo "ERROR: $repo is not in a clean, mergeable state (uncommitted changes present that this invocation did not create) -- refusing to touch it. A human must investigate $repo directly before this can retry." >&2
  printf '%s\n' "$repo_dirty" >&2
  exit 2
fi

merge_output="$(git -C "$repo" merge --no-ff "$branch" -m "$message" 2>&1)"
merge_rc=$?
if [ "$merge_rc" -ne 0 ]; then
  git -C "$repo" merge --abort >/dev/null 2>&1 || true
  _release_lock
  echo "MERGE CONFLICT merging '$branch' into '$base' in $repo (aborted, $repo left unchanged):" >&2
  printf '%s\n' "$merge_output" >&2
  _append_ledger_or_warn MERGE_CONFLICT ""
  exit 3
fi

merged_sha="$(git -C "$repo" rev-parse HEAD)"

push_output="$(git -C "$repo" push origin "$base" 2>&1)"
push_rc=$?
if [ "$push_rc" -ne 0 ]; then
  _release_lock
  echo "PUSH FAILED pushing '$base' to origin from $repo:" >&2
  printf '%s\n' "$push_output" >&2
  echo "NOTE: the local merge commit $merged_sha for '$branch' already landed on '$base' in $repo -- it was NOT reverted. Only the push to origin needs a manual retry, e.g.: git -C $repo push origin $base" >&2
  _append_ledger_or_warn PUSH_FAILED ""
  exit 4
fi

_append_ledger_or_warn SUCCESS "$merged_sha"
_release_lock
echo "merged $branch -> $base as $merged_sha (pushed to origin)"
exit 0
