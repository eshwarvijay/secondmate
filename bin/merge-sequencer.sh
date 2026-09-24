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
#             this invocation did not create) | 3 THIS invocation's own 'git merge' failing -- either a
#             real content conflict (MERGE_CONFLICT, 'git ls-files -u' non-empty) or a rejection with no
#             actual conflict, e.g. a pre-merge-commit policy hook (MERGE_REJECTED, 'git ls-files -u'
#             empty) -- both abort cleanly and leave $repo unchanged | 4 push failed (local merge already
#             landed) | 5 lock timeout | 6 --preflight-only conflict detected | 7 --preflight-only
#             unsupported/inconclusive (git doesn't support --write-tree, or another error) | 8
#             --preflight-only clean (no conflict detected).
#             --preflight-only (6-8) is a READ-ONLY CHECK OF $repo's WORKING TREE, INDEX,
#             HEAD/BRANCH REFS, LOCK, AND LEDGER SPECIFICALLY -- it never touches any of those five
#             things, on any exit path. It is NOT read-only with respect to $repo's git internals
#             in general: it runs a normal 'git fetch' of --base (which, like any fetch, writes
#             .git/FETCH_HEAD, updates refs/remotes/origin/<base>, and downloads any new objects)
#             and a 'git merge-tree --write-tree' conflict check (which writes the computed
#             merge-result tree, and any conflict blobs, into the object database as an
#             unreachable, git-gc'able dangling object -- the git-recommended, exit-code-reliable
#             way to check for a conflict; the only alternative, the legacy 3-arg 'git merge-tree'
#             without --write-tree, writes nothing but requires parsing unstructured text output
#             instead of a clean 0/1 exit code). Both are the ordinary, unavoidable footprint of
#             doing this check via git's own supported mechanisms, not a growing exceptions list.
#             Note: exit codes 6-8 are ONLY for --preflight-only and never occur in normal merge+push flow.
#             Existing exit codes (0-5) are unchanged and have identical semantics to today.
#
# Ledger reason_code is a CLOSED enum: SUCCESS | GATE_REFUSE | BRANCH_MISMATCH | MERGE_CONFLICT |
#             MERGE_REJECTED | PUSH_FAILED | PUSH_RACE_RECOVERED | PUSH_RACE_EXHAUSTED | LOCK_TIMEOUT -- never freeform.
#
# Settled scope (do not re-litigate): no retry of anything OTHER than a confirmed push race (see
# P1 above -- bounded at 3 total attempts, never on a hook/protected-branch rejection), no
# rebase-in-place on refusal, no priority queue / fairness policy, no automatic stale-lock
# expiry/steal, single machine only.
#
# Accepted limitation (documented, not chased further): if $repo has an executable 'pre-push'
# hook installed (checked via _repo_has_pre_push_hook, respecting core.hooksPath), P1's push-race
# auto-recovery is disabled ENTIRELY for that repo -- every push failure is reported as PUSH_FAILED,
# never retried, even a genuine one. A LOCAL pre-push hook runs client-side, before git ever
# attempts the network-level push, so its stderr has no "remote: " relay prefix or any other
# structural marker distinguishing it from git's own client-generated race text -- unlike a
# server-side hook (pre-receive/update), which is always relayed through that exact, un-spoofable
# prefix. There is no text pattern that can safely tell "genuine race" from "pre-push hook's own
# arbitrary message" apart in that case, so this trades away auto-recovery specifically for repos
# with a local pre-push hook installed, in exchange for never retrying (and thereby hiding) a
# permanent policy rejection. A human can always retry the push manually in that case.
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

# Prints the path of $2 relative to repo dir $1, for use as a git pathspec (git resolves bare
# pathspecs relative to the effective cwd, which is $1 since every git call here uses `-C "$1"`).
# Deliberately EXACT-PATH, not basename -- a basename-only exclusion (an earlier revision's bug) would
# swallow any unrelated path in the repo that merely shares that NAME, which is wrong. Prints NOTHING
# or something starting with "$1" -- callers should treat an empty result as "no exclusion needed/possible"
# and omit the pathspec entirely, never fall back to passing an absolute, out-of-repo path as a literal
# pathspec: git treats that as a real filesystem path and fatally errors 'outside repository' rather than
# just harmlessly not matching (verified empirically) -- so "no pathspec at all" is the correct no-op, not
# a special string.
_repo_relative_path() {
  local repo_abs target_abs
  repo_abs="$(cd "$1" 2>/dev/null && pwd)" || return
  if target_abs="$(cd "$(dirname "$2")" 2>/dev/null && pwd)"; then
    target_abs="$target_abs/$(basename "$2")"
  else
    # target's parent doesn't exist yet (e.g. the ledger's directory before any append has ever
    # happened) -- fall back to pure string-prefix matching against $1 as given, since LOCK_DIR/LEDGER
    # are constructed as "$repo/..." verbatim in the default (no-override) case; nothing can be "dirty"
    # under a directory that doesn't exist, so an empty result here is always safe either way.
    case "$2" in
      "$1"/*) target_abs="$repo_abs/${2#"$1"/}" ;;
      *) return ;;
    esac
  fi
  case "$target_abs" in
    "$repo_abs"/*) echo "${target_abs#"$repo_abs"/}" ;;
    "$repo_abs") echo "." ;;
    *) return ;;
  esac
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
       merge-sequencer.sh --repo PATH --worktree PATH --branch NAME --base REF --checked-sha SHA
                           --preflight-only
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

  # ---- Test 13: the dirty-check's own-artifact exclusion must be EXACT-PATH, not basename. A legitimate
  # SM_LOOP_STATE override whose basename happens to be 'foo' must NEVER swallow a genuinely dirty,
  # completely unrelated TRACKED file living in a DIFFERENT 'foo/' directory that actually lives inside
  # the repo -- a basename-only exclusion (an earlier revision's bug) would incorrectly match it.
  IFS='|' read -r origin13 primary13 <<<"$(_setup_repo 13)"
  git -C "$primary13" worktree add -q "$t/wt13" -b sm/basename-collision main
  echo "feature-m" >> "$t/wt13/file.txt"
  git -C "$t/wt13" commit -qam "feature m"
  sha13="$(git -C "$t/wt13" rev-parse HEAD)"
  mkdir -p "$primary13/foo"
  echo "tracked" > "$primary13/foo/tracked.txt"
  git -C "$primary13" add foo/tracked.txt
  git -C "$primary13" commit -qam "add unrelated foo/ dir (inside the repo, nothing to do with the lock)"
  echo "real dirty change" >> "$primary13/foo/tracked.txt"
  lock_root13="$t/state13-root/foo"   # a legitimate override whose OWN basename also happens to be 'foo'
  main_before13="$(git -C "$primary13" rev-parse main)"
  out13="$(SM_LOOP_STATE="$lock_root13" bash "$MS" --repo "$primary13" --worktree "$t/wt13" --branch sm/basename-collision --base main --checked-sha "$sha13" --wait-timeout 5 2>&1)"
  rc13=$?
  [ "$rc13" -eq 2 ] || { echo "FAIL: real unrelated dirty content in a same-named 'foo/' dir must still refuse, got rc=$rc13: $out13"; fails=1; }
  main_after13="$(git -C "$primary13" rev-parse main)"
  [ "$main_after13" = "$main_before13" ] || { echo "FAIL: main was touched despite real unrelated dirty content being wrongly swallowed by a basename collision"; fails=1; }

  # ---- Test 14: two SEQUENTIAL successful merges against the SAME repo, both using the real DEFAULT
  # configuration (no env overrides, no pre-existing .gitignore for .secondmate/ or audit/). The second
  # must succeed exactly like the first, not be refused because of the first merge's own leftover
  # untracked audit/ ledger artifact (Bug B: only the lock was ever excluded, never the ledger).
  IFS='|' read -r origin14 primary14 <<<"$(_setup_repo 14)"
  git -C "$primary14" worktree add -q "$t/wt14a" -b sm/seq-a main
  echo "feature-n" >> "$t/wt14a/file.txt"
  git -C "$t/wt14a" commit -qam "feature n"
  sha14a="$(git -C "$t/wt14a" rev-parse HEAD)"
  out14a="$(unset SM_LOOP_STATE SM_MERGE_LEDGER; bash "$MS" --repo "$primary14" --worktree "$t/wt14a" --branch sm/seq-a --base main --checked-sha "$sha14a" --wait-timeout 5 2>&1)"
  rc14a=$?
  [ "$rc14a" -eq 0 ] || { echo "FAIL: first sequential default merge expected rc=0, got $rc14a: $out14a"; fails=1; }
  git -C "$primary14" worktree add -q "$t/wt14b" -b sm/seq-b main
  echo "feature-o" > "$t/wt14b/file2.txt"
  git -C "$t/wt14b" add file2.txt
  git -C "$t/wt14b" commit -qam "feature o"
  sha14b="$(git -C "$t/wt14b" rev-parse HEAD)"
  main_before14b="$(git -C "$primary14" rev-parse main)"
  out14b="$(unset SM_LOOP_STATE SM_MERGE_LEDGER; bash "$MS" --repo "$primary14" --worktree "$t/wt14b" --branch sm/seq-b --base main --checked-sha "$sha14b" --wait-timeout 5 2>&1)"
  rc14b=$?
  [ "$rc14b" -eq 0 ] || { echo "FAIL: second sequential default merge expected rc=0, got $rc14b: $out14b (first merge's own audit/ ledger artifact wrongly refused it)"; fails=1; }
  main_after14b="$(git -C "$primary14" rev-parse main)"
  [ "$main_after14b" != "$main_before14b" ] || { echo "FAIL: second sequential default merge did not advance main"; fails=1; }
  grep -q '"reason_code": *"SUCCESS"' "$primary14/audit/merge-ledger.jsonl" 2>/dev/null || { echo "FAIL: expected SUCCESS records in the default ledger after two sequential merges"; fails=1; }

  # ---- Test 15: PUSH_FAILED has real, automated regression coverage -- a bare origin with a rejecting
  # pre-receive hook makes 'git push' fail deterministically AFTER a genuinely successful local merge.
  IFS='|' read -r origin15 primary15 <<<"$(_setup_repo 15)"
  cat > "$origin15/hooks/pre-receive" <<'HOOKEOF'
#!/bin/sh
echo "rejected by pre-receive hook (test)" >&2
exit 1
HOOKEOF
  chmod +x "$origin15/hooks/pre-receive"
  git -C "$primary15" worktree add -q "$t/wt15" -b sm/push-fail main
  echo "feature-p" >> "$t/wt15/file.txt"
  git -C "$t/wt15" commit -qam "feature p"
  sha15="$(git -C "$t/wt15" rev-parse HEAD)"
  main_before15="$(git -C "$primary15" rev-parse main)"
  origin15_before="$(git --git-dir="$origin15" rev-parse main 2>/dev/null || echo "")"
  out15="$(_ms --repo "$primary15" --worktree "$t/wt15" --branch sm/push-fail --base main --checked-sha "$sha15" --wait-timeout 5 2>&1)"
  rc15=$?
  [ "$rc15" -eq 4 ] || { echo "FAIL: rejected push expected rc=4, got $rc15: $out15"; fails=1; }
  main_after15="$(git -C "$primary15" rev-parse main)"
  [ "$main_after15" != "$main_before15" ] || { echo "FAIL: local merge commit was not retained despite the push being rejected"; fails=1; }
  origin15_after="$(git --git-dir="$origin15" rev-parse main 2>/dev/null || echo "")"
  [ "$origin15_after" = "$origin15_before" ] || { echo "FAIL: origin main changed despite the push being rejected"; fails=1; }
  echo "$out15" | grep -qi "PUSH FAILED" || { echo "FAIL: expected a PUSH FAILED message in output, got: $out15"; fails=1; }
  [ "$(_ledger_count sm/push-fail PUSH_FAILED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_FAILED ledger record for sm/push-fail"; fails=1; }

  # ---- Test 16: --worktree must be an ACTUAL linked worktree of --repo (sharing --repo's
  # git-common-dir), never an independent clone -- an independent clone can pass verify-gate.sh's own
  # freshness check against its own STALE local refs (commit SHAs are portable across clones) while the
  # real merge lands into --repo's actual, newer state, silently bypassing the freshness guarantee.
  IFS='|' read -r origin16 primary16 <<<"$(_setup_repo 16)"
  git clone -q "$primary16" "$t/stale-clone16" >/dev/null 2>&1
  git -C "$t/stale-clone16" checkout -q -b sm/stale-feature main
  echo "feature-q" >> "$t/stale-clone16/file.txt"
  git -C "$t/stale-clone16" commit -qam "feature q (committed on top of a stale clone's own main)"
  sha16="$(git -C "$t/stale-clone16" rev-parse HEAD)"
  # Fetch that exact commit into $repo too, so it resolves there with the SAME SHA (round 3's own
  # branch-identity check must not be what refuses this -- this test isolates the git-common-dir issue
  # specifically; realistically the sub-agent-supervisor's branch is normally visible to the primary
  # checkout one way or another, which is exactly why the git-common-dir identity check, not branch
  # resolvability, is the only thing standing between this and a silent bypass).
  git -C "$primary16" fetch -q "$t/stale-clone16" sm/stale-feature:sm/stale-feature
  # $repo's REAL main advances independently, with an unrelated, NON-CONFLICTING change the stale
  # clone above never fetched and knows nothing about.
  echo "unrelated-real-advance" >> "$primary16/other-file.txt"
  git -C "$primary16" add other-file.txt
  git -C "$primary16" commit -qam "real main genuinely advances, unrelated to the stale clone"
  git -C "$primary16" push -q origin main
  main_before16="$(git -C "$primary16" rev-parse main)"
  origin16_before="$(git --git-dir="$origin16" rev-parse main 2>/dev/null || echo "")"
  out16="$(_ms --repo "$primary16" --worktree "$t/stale-clone16" --branch sm/stale-feature --base main --checked-sha "$sha16" --wait-timeout 5 2>&1)"
  rc16=$?
  [ "$rc16" -eq 2 ] || { echo "FAIL: an independent clone passed as --worktree should be refused with rc=2, got $rc16: $out16"; fails=1; }
  echo "$out16" | grep -qi "not a linked worktree" || { echo "FAIL: expected a clear 'not a linked worktree' explanation, got: $out16"; fails=1; }
  echo "$out16" | grep -qi "PASS:\|REFUSE:" && { echo "FAIL: verify-gate.sh appears to have been reached at all -- the git-common-dir check must refuse BEFORE calling it, got: $out16"; fails=1; }
  main_after16="$(git -C "$primary16" rev-parse main)"
  [ "$main_after16" = "$main_before16" ] || { echo "FAIL: main was touched despite --worktree being an independent, stale clone (the exact bug being regression-tested)"; fails=1; }
  origin16_after="$(git --git-dir="$origin16" rev-parse main 2>/dev/null || echo "")"
  [ "$origin16_after" = "$origin16_before" ] || { echo "FAIL: origin main changed despite --worktree being an independent, stale clone"; fails=1; }

  # ---- Test 17: a 'git merge' failure that is NOT a real content conflict (e.g. a repo-configured
  # pre-merge-commit policy hook rejecting it) must be classified as MERGE_REJECTED, not MERGE_CONFLICT
  # -- 'git ls-files -u' (no unmerged paths) is the ground truth distinguishing the two. Still aborts
  # cleanly and leaves $repo unchanged either way.
  IFS='|' read -r origin17 primary17 <<<"$(_setup_repo 17)"
  git -C "$primary17" worktree add -q "$t/wt17" -b sm/hook-reject main
  echo "feature-r" >> "$t/wt17/file.txt"
  git -C "$t/wt17" commit -qam "feature r"
  sha17="$(git -C "$t/wt17" rev-parse HEAD)"
  mkdir -p "$primary17/.git/hooks"
  cat > "$primary17/.git/hooks/pre-merge-commit" <<'HOOKEOF'
#!/bin/sh
echo "REJECTED BY POLICY: sign-off required (test hook)" >&2
exit 1
HOOKEOF
  chmod +x "$primary17/.git/hooks/pre-merge-commit"
  before17="$(git -C "$primary17" rev-parse HEAD)"
  out17="$(_ms --repo "$primary17" --worktree "$t/wt17" --branch sm/hook-reject --base main --checked-sha "$sha17" --wait-timeout 5 2>&1)"
  rc17=$?
  [ "$rc17" -eq 3 ] || { echo "FAIL: pre-merge-commit hook rejection expected rc=3, got $rc17: $out17"; fails=1; }
  echo "$out17" | grep -qi "MERGE REJECTED" || { echo "FAIL: expected MERGE REJECTED framing (not generic conflict), got: $out17"; fails=1; }
  echo "$out17" | grep -q "REJECTED BY POLICY" || { echo "FAIL: expected the hook's own policy message to appear verbatim, got: $out17"; fails=1; }
  after17="$(git -C "$primary17" rev-parse HEAD)"
  [ "$before17" = "$after17" ] || { echo "FAIL: primary HEAD moved despite hook rejection"; fails=1; }
  [ -z "$(git -C "$primary17" status --porcelain)" ] || { echo "FAIL: primary left dirty after hook rejection (no abort?)"; fails=1; }
  [ ! -e "$primary17/.git/MERGE_HEAD" ] || { echo "FAIL: MERGE_HEAD still present after hook rejection (merge not aborted)"; fails=1; }
  [ "$(_ledger_count sm/hook-reject MERGE_REJECTED)" = "1" ] || { echo "FAIL: expected exactly one MERGE_REJECTED ledger record"; fails=1; }
  [ "$(_ledger_count sm/hook-reject MERGE_CONFLICT)" = "0" ] || { echo "FAIL: a hook rejection must NOT be logged as MERGE_CONFLICT -- the whole point of the closed-enum distinction"; fails=1; }

  # ---- Test 18: (P1) genuine push race recovers successfully within budget, leaving both changes on main ----
  IFS='|' read -r origin18 primary18 <<<"$(_setup_repo 18)"
  git -C "$primary18" worktree add -q "$t/wt18" -b sm/push-race-recover main
  echo "feature-race" >> "$t/wt18/file.txt"
  git -C "$t/wt18" commit -qam "feature race"
  sha18="$(git -C "$t/wt18" rev-parse HEAD)"
  main_before18="$(git -C "$primary18" rev-parse main)"
  # Prime origin with a concurrent push to create a real fast-forward race
  git -C "$primary18" fetch origin >/dev/null 2>&1
  # Create another commit on origin that will race with our push
  # CRITICAL: use a different file so there's no content conflict during recovery merge
  git -C "$primary18" checkout -q -b temp-race main
  echo "temp-race-commit" > "$primary18/race-file.txt"
  git -C "$primary18" add race-file.txt
  git -C "$primary18" commit -qam "temp race commit"
  git -C "$primary18" push -q origin temp-race:main
  # Switch back to main before calling merge-sequencer.sh
  git -C "$primary18" checkout -q main
  # Now our invocation fetches, then we do a second push that will be a race
  out18="$(_ms --repo "$primary18" --worktree "$t/wt18" --branch sm/push-race-recover --base main --checked-sha "$sha18" --wait-timeout 5 2>&1)"
  rc18=$?
  [ "$rc18" -eq 0 ] || { echo "FAIL: push-race recovery expected rc=0, got $rc18: $out18"; fails=1; }
  main_after18="$(git -C "$primary18" rev-parse main)"
  # Both changes must be present on main - verify by checking the commit messages
  [ "$(git -C "$primary18" log --oneline -n 5 | grep -c 'temp race commit')" = "1" ] || { echo "FAIL: origin's temp race commit missing from main"; fails=1; }
  [ "$(git -C "$primary18" log --oneline -n 5 | grep -c 'feature race')" = "1" ] || { echo "FAIL: our feature race commit missing from main"; fails=1; }
  # Verify PUSH_RACE_RECOVERED ledger record
  [ "$(_ledger_count sm/push-race-recover PUSH_RACE_RECOVERED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_RACE_RECOVERED ledger record"; fails=1; }
  # Verify recovery commit message appears in git log
  recovery_line=$(git -C "$primary18" log --oneline | grep "merge-sequencer: race recovery")
  if [ -z "$recovery_line" ]; then
    echo "FAIL: expected a recovery-merge commit message in git log (not found)" >&2
    echo "DEBUG: git log -n 10:" >&2
    git -C "$primary18" log --oneline -n 10 >&2
    fails=1
  fi
  origin18_main="$(git --git-dir="$origin18" rev-parse main 2>/dev/null || echo "")"
  [ "$origin18_main" = "$main_after18" ] || { echo "FAIL: origin main diverged from primary main after race recovery"; fails=1; }

  # ---- Test 19: (P1) push-race exhausts all 3 attempts (persistent, genuine race signature on
  # every attempt) -> PUSH_RACE_EXHAUSTED, exit 4. Uses a fake 'git' shim (not a pre-receive hook --
  # a hook rejection must NEVER be classified as a race, see Test 20) prepended to PATH so every
  # 'git push origin main' call deterministically fails with a real race-shaped message, regardless
  # of attempt number -- this exercises the implementation's own bounded-3-attempts loop exhausting,
  # not any fixture timing. The shim must correctly skip a leading '-C <dir>' (this file always calls
  # git as 'git -C "$repo" push origin "$base"') and match on the ACTUAL pushed ref ($base, i.e.
  # 'main'), not the branch name -- an earlier revision of this test matched on the branch name and
  # never intercepted anything, since the branch name is never what gets pushed.
  IFS='|' read -r origin19 primary19 <<<"$(_setup_repo 19)"
  git -C "$primary19" worktree add -q "$t/wt19" -b sm/push-race-exhaust main
  echo "feature-exhaust" >> "$t/wt19/file.txt"
  git -C "$t/wt19" commit -qam "feature exhaust"
  sha19="$(git -C "$t/wt19" rev-parse HEAD)"
  main_before19="$(git -C "$primary19" rev-parse main)"
  # Give origin ONE genuine, real advance the primary repo doesn't have yet (via a separate clone,
  # never through $primary19), so the recovery loop's fetch+merge has real content to merge on its
  # first attempt (producing an actual, distinctive recovery commit) rather than finding origin
  # identical to what it already has -- a merge with truly nothing to merge is always a no-op
  # ("Already up to date"), even with --no-ff, and would never produce a commit at all.
  # Clone the PRIMARY checkout (has 'main' actually checked out), not the bare origin -- a bare
  # repo's HEAD symref can be stale/nonexistent after its first push (it doesn't auto-follow
  # whatever branch was pushed), which silently produces an empty, branch-less clone. Then
  # explicitly repoint the clone's 'origin' remote at the REAL shared bare origin19 -- cloning
  # from primary19 makes the clone's own 'origin' default to primary19 itself, which would refuse
  # a push to its currently-checked-out branch.
  # A separate, non-overlapping file -- touching file.txt (which the feature branch also modifies)
  # would create a genuine content conflict, not the clean divergence this test needs.
  git clone -q "$primary19" "$t/other-clone19" >/dev/null 2>&1
  git -C "$t/other-clone19" remote set-url origin "$origin19"
  echo "someone-else-raced-ahead" > "$t/other-clone19/other-file-19.txt"
  git -C "$t/other-clone19" add other-file-19.txt
  git -C "$t/other-clone19" commit -qam "a genuinely unrelated concurrent advance"
  git -C "$t/other-clone19" push -q origin main
  origin19_before="$(git --git-dir="$origin19" rev-parse main 2>/dev/null || echo "")"
  fake_git_dir19="$t/fake-git-19"
  mkdir -p "$fake_git_dir19"
  real_git_path19="$(command -v git)"
  cat > "$fake_git_dir19/git" <<GITSHIM
#!/usr/bin/env bash
real_git="$real_git_path19"
args=("\$@")
i=0
sub=""
while [ \$i -lt \${#args[@]} ]; do
  case "\${args[\$i]}" in
    -C) i=\$((i+2));;
    *) sub="\${args[\$i]}"; break;;
  esac
done
if [ "\$sub" = "push" ]; then
  echo "! [rejected]  main -> main (fetch first)" >&2
  echo "hint: Updates were rejected because the tip of your current branch is behind" >&2
  echo "hint: its remote counterpart. Integrate the remote changes before pushing again." >&2
  exit 1
fi
exec "\$real_git" "\$@"
GITSHIM
  chmod +x "$fake_git_dir19/git"
  out19="$(PATH="$fake_git_dir19:$PATH" _ms --repo "$primary19" --worktree "$t/wt19" --branch sm/push-race-exhaust --base main --checked-sha "$sha19" --wait-timeout 5 2>&1)"
  rc19=$?
  [ "$rc19" -eq 4 ] || { echo "FAIL: push-race exhausted expected rc=4, got $rc19: $out19"; fails=1; }
  main_after19="$(git -C "$primary19" rev-parse main)"
  [ "$main_after19" != "$main_before19" ] || { echo "FAIL: local merge commit not retained on push exhaustion"; fails=1; }
  origin19_after="$(git --git-dir="$origin19" rev-parse main 2>/dev/null || echo "")"
  [ "$origin19_after" = "$origin19_before" ] || { echo "FAIL: origin main moved despite push being rejected on every attempt"; fails=1; }
  if [ "$(_ledger_count sm/push-race-exhaust PUSH_RACE_EXHAUSTED)" != "1" ]; then
    echo "FAIL: expected exactly one PUSH_RACE_EXHAUSTED ledger record" >&2
    fails=1
  fi
  # Captured to a variable, then matched with bash's own '[[ == *pattern* ]]' -- no subprocess, no
  # pipe. A live 'git log | grep -q' pipe lets grep exit the instant it finds a match (always the
  # newest/first commit here), which can SIGPIPE-kill git before it finishes writing under 'set -o
  # pipefail' (line 44), making the pipeline report failure despite a real match. A 'printf | grep
  # -q' on the captured variable is NOT a full fix either -- a large enough string reproduces the
  # exact same SIGPIPE for the exact same reason (verified directly: ~200KB reliably triggers it).
  # Same bug class this repo already fixed once in bin/plan-committee.sh's collision guard --
  # eliminate the pipe entirely, don't narrow the race or shrink the payload.
  log19="$(git -C "$primary19" log --oneline)"
  if [[ "$log19" != *"merge-sequencer: race recovery"* ]]; then
    echo "FAIL: expected at least one recovery-merge commit message in git log" >&2
    fails=1
  fi

  # ---- Test 20: (P1) CRITICAL negative test - pre-receive hook rejection must NOT be classified as race ----
  # Reuse test 15's fixture: a bare origin with a rejecting pre-receive hook
  IFS='|' read -r origin20 primary20 <<<"$(_setup_repo 20)"
  cat > "$origin20/hooks/pre-receive" <<'HOOKEOF'
#!/bin/sh
echo "rejected by pre-receive hook (test)" >&2
exit 1
HOOKEOF
  chmod +x "$origin20/hooks/pre-receive"
  git -C "$primary20" worktree add -q "$t/wt20" -b sm/push-fail-20 main
  echo "feature-p20" >> "$t/wt20/file.txt"
  git -C "$t/wt20" commit -qam "feature p20"
  sha20="$(git -C "$t/wt20" rev-parse HEAD)"
  main_before20="$(git -C "$primary20" rev-parse main)"
  origin20_before="$(git --git-dir="$origin20" rev-parse main 2>/dev/null || echo "")"
  out20="$(_ms --repo "$primary20" --worktree "$t/wt20" --branch sm/push-fail-20 --base main --checked-sha "$sha20" --wait-timeout 5 2>&1)"
  rc20=$?
  [ "$rc20" -eq 4 ] || { echo "FAIL: rejected push (hook) expected rc=4, got $rc20: $out20"; fails=1; }
  main_after20="$(git -C "$primary20" rev-parse main)"
  [ "$main_after20" != "$main_before20" ] || { echo "FAIL: local merge commit was not retained despite the push being rejected"; fails=1; }
  origin20_after="$(git --git-dir="$origin20" rev-parse main 2>/dev/null || echo "")"
  [ "$origin20_after" = "$origin20_before" ] || { echo "FAIL: origin main changed despite the push being rejected"; fails=1; }
  echo "$out20" | grep -qi "PUSH FAILED" || { echo "FAIL: expected a PUSH FAILED message in output, got: $out20"; fails=1; }
  # CRITICAL: must NOT be PUSH_RACE_* -- must be exactly PUSH_FAILED
  [ "$(_ledger_count sm/push-fail-20 PUSH_RACE_RECOVERED)" = "0" ] || { echo "FAIL: hook rejection was wrongly classified as PUSH_RACE_RECOVERED"; fails=1; }
  [ "$(_ledger_count sm/push-fail-20 PUSH_RACE_EXHAUSTED)" = "0" ] || { echo "FAIL: hook rejection was wrongly classified as PUSH_RACE_EXHAUSTED"; fails=1; }
  [ "$(_ledger_count sm/push-fail-20 PUSH_FAILED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_FAILED ledger record for hook rejection"; fails=1; }
  # Verify NO recovery-merge commit exists (hook rejection should not trigger any retry).
  # Captured + matched with '[[ == * ]]', no pipe -- see Test 19's identical comment for why
  # even a captured-variable pipe to grep -q is unsafe (SIGPIPE under pipefail) for large input.
  log20="$(git -C "$primary20" log --oneline)"
  [[ "$log20" == *"merge-sequencer: race recovery"* ]] && { echo "FAIL: hook rejection wrongly triggered a recovery-merge commit (retry should NOT have happened)"; fails=1; } || true

  # ---- Test 21: (P1) recovery merge itself conflicts -> escalate, main left at state after FIRST merge ----
  IFS='|' read -r origin21 primary21 <<<"$(_setup_repo 21)"
  git -C "$primary21" worktree add -q "$t/wt21" -b sm/push-race-conflict main
  echo "feature-conflict" >> "$t/wt21/file.txt"
  git -C "$t/wt21" commit -qam "feature conflict"
  sha21="$(git -C "$t/wt21" rev-parse HEAD)"
  main_before21="$(git -C "$primary21" rev-parse main)"
  # Make origin advance with conflicting changes to force recovery merge conflict
  git -C "$primary21" fetch origin >/dev/null 2>&1
  # Create conflicting changes on origin - use SAME file to ensure conflict
  git -C "$primary21" checkout -q -b conflict-race main
  echo "conflict-on-origin" >> "$primary21/file.txt"
  git -C "$primary21" commit -qam "origin conflict commit"
  git -C "$primary21" push -q origin conflict-race:main
  # Switch back to main before calling merge-sequencer.sh
  git -C "$primary21" checkout -q main
  out21="$(_ms --repo "$primary21" --worktree "$t/wt21" --branch sm/push-race-conflict --base main --checked-sha "$sha21" --wait-timeout 5 2>&1)"
  rc21=$?
  # After 3 exhausted attempts, should escalate with exit 4 (PUSH_RACE_EXHAUSTED logic)
  [ "$rc21" -eq 4 ] || { echo "FAIL: recovery merge conflict exhaustion expected rc=4, got $rc21: $out21"; fails=1; }
  main_after21="$(git -C "$primary21" rev-parse main)"
  # The FIRST (original) merge should still be present on main
  [ "$main_after21" != "$main_before21" ] || { echo "FAIL: main not advanced despite first merge landing"; fails=1; }
  # Verify the conflict resolution marker is the FIRST merge (not corrupted by failed recovery).
  # Captured + matched with '[[ == * ]]' in both checks below, no pipe at all -- see Test 19's
  # identical comment for why even a captured-variable pipe to grep -q is unsafe for large input.
  log21="$(git -C "$primary21" log --oneline)"
  [[ "$log21" == *"feature conflict"* ]] || { echo "FAIL: first merge's feature conflict commit missing from main"; fails=1; }
  # Verify no recovery merge commit for conflict case (failed on first attempt, no retries)
  [[ "$log21" == *"merge-sequencer: race recovery"* ]] && { echo "FAIL: conflict case should not have recovery commits"; fails=1; } || true
  [ "$(_ledger_count sm/push-race-conflict PUSH_RACE_EXHAUSTED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_RACE_EXHAUSTED ledger record for recovery conflict"; fails=1; }

  # ---- Test 22: (P2) --preflight-only with clean merge (no conflict) -> exit 6, zero side effects ----
  IFS='|' read -r origin22 primary22 <<<"$(_setup_repo 22)"
  git -C "$primary22" worktree add -q "$t/wt22" -b sm/preflight-clean main
  echo "feature-preflight" >> "$t/wt22/file.txt"
  git -C "$t/wt22" commit -qam "feature preflight clean"
  sha22="$(git -C "$t/wt22" rev-parse HEAD)"
  main_before22="$(git -C "$primary22" rev-parse main)"
  lock_dir22="$primary22/.secondmate/merge-sequencer.lock"
  # Count ledger entries before preflight
  ledger_lines_before=$(wc -l < "$ledger_default" 2>/dev/null || echo 0)
  out22="$(_ms --repo "$primary22" --worktree "$t/wt22" --branch sm/preflight-clean --base main --checked-sha "$sha22" --preflight-only --wait-timeout 5 2>&1)"
  rc22=$?
  [ "$rc22" -eq 8 ] || { echo "FAIL: preflight clean expected rc=8, got $rc22: $out22"; fails=1; }
  echo "$out22" | grep -qi "preflight.*clean\|no conflict\|clean" || { echo "FAIL: expected a clean/no-conflict message, got: $out22"; fails=1; }
  # Zero side effects: no lock dir, no merge commit, no ledger entry
  [ ! -d "$lock_dir22" ] || { echo "FAIL: preflight clean created lock directory (should be read-only)"; fails=1; }
  main_after22="$(git -C "$primary22" rev-parse main)"
  [ "$main_after22" = "$main_before22" ] || { echo "FAIL: preflight clean advanced main when it should be read-only"; fails=1; }
  # Check ledger wasn't modified during preflight
  ledger_lines_after=$(wc -l < "$ledger_default" 2>/dev/null || echo 0)
  [ "$ledger_lines_after" = "$ledger_lines_before" ] || { echo "FAIL: preflight clean wrote to ledger (should be read-only, lines before=$ledger_lines_before after=$ledger_lines_after)"; fails=1; }
  [ ! -e "$primary22/.git/MERGE_HEAD" ] || { echo "FAIL: preflight clean left MERGE_HEAD (should be read-only)"; fails=1; }
  [ -z "$(git -C "$primary22" status --porcelain 2>/dev/null)" ] || { echo "FAIL: preflight clean left repo dirty (should be read-only)"; fails=1; }

  # ---- Test 23: (P2) --preflight-only with conflict -> exit 6 (conflict), no side effects ----
  # git merge-tree --write-tree exits 1 on conflict -> we map to exit 6 for --preflight-only conflict
  IFS='|' read -r origin23 primary23 <<<"$(_setup_repo 23)"
  git -C "$primary23" worktree add -q "$t/wt23" -b sm/preflight-conflict main
  echo "conflict-A" > "$t/wt23/file.txt"
  git -C "$t/wt23" commit -qam "A (branch conflict)"
  sha23="$(git -C "$t/wt23" rev-parse HEAD)"
  echo "conflict-B" > "$primary23/file.txt"
  git -C "$primary23" commit -qam "B (main conflict)"
  git -C "$primary23" push -q origin main
  main_before23="$(git -C "$primary23" rev-parse main)"
  out23="$(_ms --repo "$primary23" --worktree "$t/wt23" --branch sm/preflight-conflict --base main --checked-sha "$sha23" --preflight-only --wait-timeout 5 2>&1)"
  rc23=$?
  [ "$rc23" -eq 6 ] || { echo "FAIL: preflight conflict expected rc=6, got $rc23: $out23"; fails=1; }
  echo "$out23" | grep -qi "conflict\|stale\|merge origin.*base.*branch" || { echo "FAIL: expected a conflict message with actionable advice, got: $out23"; fails=1; }
  # Zero side effects even for conflict
  lock_dir23="$primary23/.secondmate/merge-sequencer.lock"
  [ ! -d "$lock_dir23" ] || { echo "FAIL: preflight conflict created lock directory (should be read-only)"; fails=1; }
  main_after23="$(git -C "$primary23" rev-parse main)"
  [ "$main_after23" = "$main_before23" ] || { echo "FAIL: preflight conflict advanced main when it should be read-only"; fails=1; }
  [ ! -e "$primary23/.git/MERGE_HEAD" ] || { echo "FAIL: preflight conflict left MERGE_HEAD (should be read-only, never merges)"; fails=1; }

  # ---- Test 24: (P2) --preflight-only normal happy path validation ----
  IFS='|' read -r origin24 primary24 <<<"$(_setup_repo 24)"
  git -C "$primary24" worktree add -q "$t/wt24" -b sm/preflight-normal main
  echo "feature-normal" >> "$t/wt24/file.txt"
  git -C "$t/wt24" commit -qam "feature normal"
  sha24="$(git -C "$t/wt24" rev-parse HEAD)"
  # Verify normal success path
  out24="$(_ms --repo "$primary24" --worktree "$t/wt24" --branch sm/preflight-normal --base main --checked-sha "$sha24" --preflight-only --wait-timeout 5 2>&1)"
  rc24=$?
  [ "$rc24" -eq 8 ] || { echo "FAIL: preflight normal clean expected rc=8, got $rc24: $out24"; fails=1; }
  echo "$out24" | grep -qi "preflight.*clean\|no conflict" || { echo "FAIL: expected a clean/no-conflict message for preflight normal, got: $out24"; fails=1; }

  # ---- Test 25: (P1) CRITICAL negative test -- a hook rejection whose OWN message happens to
  # contain a race keyword ("behind") must still be PUSH_FAILED, never retried as a race. A real
  # hook's message is admin-authored, arbitrary text; classifying by keyword presence alone would
  # retry a permanent policy rejection forever. Reuses the real-hook fixture pattern from Test
  # 17/20 (not the fake shim -- this needs git's OWN real "remote: "/"[remote rejected]" framing).
  IFS='|' read -r origin25 primary25 <<<"$(_setup_repo 25)"
  cat > "$origin25/hooks/pre-receive" <<'HOOKEOF'
#!/bin/sh
echo "rejected because branch is behind policy" >&2
exit 1
HOOKEOF
  chmod +x "$origin25/hooks/pre-receive"
  git -C "$primary25" worktree add -q "$t/wt25" -b sm/hook-behind-collision main
  echo "feature-p25" >> "$t/wt25/file.txt"
  git -C "$t/wt25" commit -qam "feature p25"
  sha25="$(git -C "$t/wt25" rev-parse HEAD)"
  main_before25="$(git -C "$primary25" rev-parse main)"
  out25="$(_ms --repo "$primary25" --worktree "$t/wt25" --branch sm/hook-behind-collision --base main --checked-sha "$sha25" --wait-timeout 5 2>&1)"
  rc25=$?
  [ "$rc25" -eq 4 ] || { echo "FAIL: hook rejection containing 'behind' expected rc=4, got $rc25: $out25"; fails=1; }
  main_after25="$(git -C "$primary25" rev-parse main)"
  [ "$main_after25" != "$main_before25" ] || { echo "FAIL: local merge commit was not retained despite the push being rejected"; fails=1; }
  echo "$out25" | grep -qi "PUSH FAILED" || { echo "FAIL: expected a PUSH FAILED message, got: $out25"; fails=1; }
  # The whole point of this test: must be PUSH_FAILED, NOT retried into PUSH_RACE_EXHAUSTED,
  # despite the hook's own message containing the word "behind" (in the race regex).
  [ "$(_ledger_count sm/hook-behind-collision PUSH_FAILED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_FAILED ledger record (hook message collided with a race keyword)"; fails=1; }
  [ "$(_ledger_count sm/hook-behind-collision PUSH_RACE_EXHAUSTED)" = "0" ] || { echo "FAIL: hook rejection containing 'behind' was wrongly retried and classified as PUSH_RACE_EXHAUSTED -- the exact keyword-collision bug this test guards"; fails=1; }
  [ "$(_ledger_count sm/hook-behind-collision PUSH_RACE_RECOVERED)" = "0" ] || { echo "FAIL: hook rejection containing 'behind' was wrongly classified as PUSH_RACE_RECOVERED"; fails=1; }
  log25="$(git -C "$primary25" log --oneline)"
  [[ "$log25" != *"merge-sequencer: race recovery"* ]] || { echo "FAIL: hook rejection containing 'behind' wrongly triggered a recovery-merge commit"; fails=1; }

  # ---- Test 26: (P1) exhaustion performs EXACTLY 3 total push attempts (1 initial + 2 retries),
  # never a 4th. The fake shim below counts every real 'push' invocation it intercepts by
  # appending one line per call to a counter file. ----
  IFS='|' read -r origin26 primary26 <<<"$(_setup_repo 26)"
  git -C "$primary26" worktree add -q "$t/wt26" -b sm/push-race-count main
  echo "feature-count" >> "$t/wt26/file.txt"
  git -C "$t/wt26" commit -qam "feature count"
  sha26="$(git -C "$t/wt26" rev-parse HEAD)"
  counter26="$t/push-attempt-counter-26"
  : > "$counter26"
  fake_git_dir26="$t/fake-git-26"
  mkdir -p "$fake_git_dir26"
  real_git_path26="$(command -v git)"
  cat > "$fake_git_dir26/git" <<GITSHIM
#!/usr/bin/env bash
real_git="$real_git_path26"
args=("\$@")
i=0
sub=""
while [ \$i -lt \${#args[@]} ]; do
  case "\${args[\$i]}" in
    -C) i=\$((i+2));;
    *) sub="\${args[\$i]}"; break;;
  esac
done
if [ "\$sub" = "push" ]; then
  echo "attempt" >> "$counter26"
  echo "! [rejected]  main -> main (fetch first)" >&2
  exit 1
fi
exec "\$real_git" "\$@"
GITSHIM
  chmod +x "$fake_git_dir26/git"
  out26="$(PATH="$fake_git_dir26:$PATH" _ms --repo "$primary26" --worktree "$t/wt26" --branch sm/push-race-count --base main --checked-sha "$sha26" --wait-timeout 5 2>&1)"
  rc26=$?
  [ "$rc26" -eq 4 ] || { echo "FAIL: push-race count test expected rc=4, got $rc26: $out26"; fails=1; }
  attempt_count26="$(wc -l < "$counter26" | tr -d ' ')"
  [ "$attempt_count26" = "3" ] || { echo "FAIL: expected exactly 3 total push attempts (1 initial + 2 retries), got $attempt_count26"; fails=1; }

  # ---- Test 27: (P1) a hook rejection with a LARGE message (well over a pipe buffer) must still
  # be correctly classified as PUSH_FAILED, never PUSH_RACE_EXHAUSTED -- proves the classifier's
  # own bash-native '[[ =~ ]]'/'[[ == * ]]' matching (no subprocess, no pipe) is genuinely immune
  # to the SIGPIPE-under-pipefail class this diff fixes, regardless of payload size. ----
  IFS='|' read -r origin27 primary27 <<<"$(_setup_repo 27)"
  python3 -c "
print('#!/bin/sh')
print('echo \'' + ('x' * 200000) + '\' >&2')
print('echo \"remote: rejected because branch is behind policy\" >&2')
print('exit 1')
" > "$origin27/hooks/pre-receive"
  chmod +x "$origin27/hooks/pre-receive"
  git -C "$primary27" worktree add -q "$t/wt27" -b sm/hook-large-message main
  echo "feature-p27" >> "$t/wt27/file.txt"
  git -C "$t/wt27" commit -qam "feature p27"
  sha27="$(git -C "$t/wt27" rev-parse HEAD)"
  out27="$(_ms --repo "$primary27" --worktree "$t/wt27" --branch sm/hook-large-message --base main --checked-sha "$sha27" --wait-timeout 5 2>&1)"
  rc27=$?
  [ "$rc27" -eq 4 ] || { echo "FAIL: large hook rejection expected rc=4, got $rc27"; fails=1; }
  [ "$(_ledger_count sm/hook-large-message PUSH_FAILED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_FAILED ledger record for a large hook rejection message"; fails=1; }
  [ "$(_ledger_count sm/hook-large-message PUSH_RACE_EXHAUSTED)" = "0" ] || { echo "FAIL: a large hook rejection message was wrongly retried into PUSH_RACE_EXHAUSTED"; fails=1; }

  # ---- Test 28: (P1) an 'update' hook (not 'pre-receive') whose message contains a race keyword
  # ("behind") but NONE of hook_rejection_regex's literal keywords, and whose git-generated summary
  # says only "(hook declined)" -- NOT "(pre-receive hook declined)" -- must still be classified as
  # PUSH_FAILED via the "remote: "/"[remote rejected]" structural check alone, since no keyword
  # match exists anywhere. Verified empirically: a real local 'update' hook produces exactly this
  # wording on this git version. This is the one real case that isolates the "remote:" check as
  # the sole discriminator -- unlike Test 25/27, whose 'pre-receive' hooks are ALSO caught by
  # hook_rejection_regex's literal "pre-receive" keyword via git's own separate boilerplate. ----
  IFS='|' read -r origin28 primary28 <<<"$(_setup_repo 28)"
  cat > "$origin28/hooks/update" <<'HOOKEOF'
#!/bin/sh
echo "access denied: your changes are behind the required baseline" >&2
exit 1
HOOKEOF
  chmod +x "$origin28/hooks/update"
  git -C "$primary28" worktree add -q "$t/wt28" -b sm/update-hook-behind main
  echo "feature-p28" >> "$t/wt28/file.txt"
  git -C "$t/wt28" commit -qam "feature p28"
  sha28="$(git -C "$t/wt28" rev-parse HEAD)"
  out28="$(_ms --repo "$primary28" --worktree "$t/wt28" --branch sm/update-hook-behind --base main --checked-sha "$sha28" --wait-timeout 5 2>&1)"
  rc28=$?
  [ "$rc28" -eq 4 ] || { echo "FAIL: update-hook 'behind' collision expected rc=4, got $rc28: $out28"; fails=1; }
  echo "$out28" | grep -qi "PUSH FAILED" || { echo "FAIL: expected a PUSH FAILED message, got: $out28"; fails=1; }
  [ "$(_ledger_count sm/update-hook-behind PUSH_FAILED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_FAILED ledger record (update hook, no keyword match, must rely on 'remote:' framing)"; fails=1; }
  [ "$(_ledger_count sm/update-hook-behind PUSH_RACE_EXHAUSTED)" = "0" ] || { echo "FAIL: update-hook rejection with no keyword match was wrongly retried into PUSH_RACE_EXHAUSTED -- the exact gap the 'remote:' structural check exists to close"; fails=1; }

  # ---- Test 29: (P1) CRITICAL negative test -- a genuine concurrent server-side ref-lock race
  # ("cannot lock ref .../"incorrect old value provided") ALSO carries "remote: "/"[remote
  # rejected]" framing (verified empirically against two real concurrent pushes to a bare repo),
  # so it must NOT be swallowed by the hook check -- it must still be recovered as a race. Uses a
  # fake shim (deterministic; a real concurrent race is inherently flaky as a regression test) that
  # returns git's own EXACT real ref-lock-race wording on the first push, then delegates to the
  # real git (letting it genuinely succeed) on retry. ----
  IFS='|' read -r origin29 primary29 <<<"$(_setup_repo 29)"
  git -C "$primary29" worktree add -q "$t/wt29" -b sm/reflock-race main
  echo "feature-reflock" >> "$t/wt29/file.txt"
  git -C "$t/wt29" commit -qam "feature reflock"
  sha29="$(git -C "$t/wt29" rev-parse HEAD)"
  fake_git_dir29="$t/fake-git-29"
  mkdir -p "$fake_git_dir29"
  real_git_path29="$(command -v git)"
  counter29="$t/reflock-push-counter-29"
  : > "$counter29"
  cat > "$fake_git_dir29/git" <<GITSHIM
#!/usr/bin/env bash
real_git="$real_git_path29"
args=("\$@")
i=0
sub=""
while [ \$i -lt \${#args[@]} ]; do
  case "\${args[\$i]}" in
    -C) i=\$((i+2));;
    *) sub="\${args[\$i]}"; break;;
  esac
done
if [ "\$sub" = "push" ]; then
  n=\$(wc -l < "$counter29" | tr -d ' ')
  echo "attempt" >> "$counter29"
  if [ "\$n" = "0" ]; then
    echo "remote: error: cannot lock ref 'refs/heads/main': is at aaaa111 but expected bbbb222" >&2
    echo "! [remote rejected]  main -> main (incorrect old value provided)" >&2
    exit 1
  fi
fi
exec "\$real_git" "\$@"
GITSHIM
  chmod +x "$fake_git_dir29/git"
  out29="$(PATH="$fake_git_dir29:$PATH" _ms --repo "$primary29" --worktree "$t/wt29" --branch sm/reflock-race --base main --checked-sha "$sha29" --wait-timeout 5 2>&1)"
  rc29=$?
  [ "$rc29" -eq 0 ] || { echo "FAIL: ref-lock race expected rc=0 (recovered), got $rc29: $out29"; fails=1; }
  [ "$(_ledger_count sm/reflock-race PUSH_RACE_RECOVERED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_RACE_RECOVERED ledger record for a real ref-lock-race message"; fails=1; }
  [ "$(_ledger_count sm/reflock-race PUSH_FAILED)" = "0" ] || { echo "FAIL: ref-lock race was wrongly classified as PUSH_FAILED (hook check ran before the ref-lock-race check) -- the exact regression this test guards"; fails=1; }

  # ---- Test 30: (P2) --preflight-only with a STALE --checked-sha (branch has since moved to a
  # newer, different tip) must refuse (exit 7), never silently check the stale SHA and report
  # PREFLIGHT OK/CONFLICT about a commit that is no longer --branch's actual current state. ----
  IFS='|' read -r origin30 primary30 <<<"$(_setup_repo 30)"
  git -C "$primary30" worktree add -q "$t/wt30" -b sm/preflight-stale main
  echo "feature-stale-v1" >> "$t/wt30/file.txt"
  git -C "$t/wt30" commit -qam "feature stale v1"
  sha30_stale="$(git -C "$t/wt30" rev-parse HEAD)"
  # Branch moves forward AFTER the SHA above was "reviewed" -- --checked-sha is now stale.
  echo "feature-stale-v2" >> "$t/wt30/file.txt"
  git -C "$t/wt30" commit -qam "feature stale v2 (branch moved on)"
  out30="$(_ms --repo "$primary30" --worktree "$t/wt30" --branch sm/preflight-stale --base main --checked-sha "$sha30_stale" --preflight-only --wait-timeout 5 2>&1)"
  rc30=$?
  [ "$rc30" -eq 7 ] || { echo "FAIL: preflight with a stale --checked-sha (branch has since moved) expected rc=7, got $rc30: $out30"; fails=1; }
  echo "$out30" | grep -qi "does not match --checked-sha\|resolves to" || { echo "FAIL: expected a branch/checked-sha mismatch explanation, got: $out30"; fails=1; }

  # ---- Test 31: (P1) CRITICAL negative test -- a REAL, plausible hook message that happens to
  # contain the free-text phrase "cannot lock ref" as ordinary policy English (not git's own
  # ref-CAS parenthetical reason) must still be PUSH_FAILED, never treated as a ref-lock race. An
  # earlier revision of _is_ref_lock_race matched this phrase anywhere in the output and was fooled
  # by exactly this kind of message -- fixed by matching ONLY the "(incorrect old value provided)"
  # parenthetical, which git itself controls and a hook cannot produce. ----
  IFS='|' read -r origin31 primary31 <<<"$(_setup_repo 31)"
  cat > "$origin31/hooks/pre-receive" <<'HOOKEOF'
#!/bin/sh
echo "policy denied: cannot lock ref writes until CAB approval" >&2
exit 1
HOOKEOF
  chmod +x "$origin31/hooks/pre-receive"
  git -C "$primary31" worktree add -q "$t/wt31" -b sm/cab-policy-collision main
  echo "feature-p31" >> "$t/wt31/file.txt"
  git -C "$t/wt31" commit -qam "feature p31"
  sha31="$(git -C "$t/wt31" rev-parse HEAD)"
  out31="$(_ms --repo "$primary31" --worktree "$t/wt31" --branch sm/cab-policy-collision --base main --checked-sha "$sha31" --wait-timeout 5 2>&1)"
  rc31=$?
  [ "$rc31" -eq 4 ] || { echo "FAIL: CAB-policy 'cannot lock ref' collision expected rc=4, got $rc31: $out31"; fails=1; }
  echo "$out31" | grep -qi "PUSH FAILED" || { echo "FAIL: expected a PUSH FAILED message, got: $out31"; fails=1; }
  [ "$(_ledger_count sm/cab-policy-collision PUSH_FAILED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_FAILED ledger record (hook message coincidentally contained 'cannot lock ref')"; fails=1; }
  [ "$(_ledger_count sm/cab-policy-collision PUSH_RACE_RECOVERED)" = "0" ] || { echo "FAIL: CAB-policy hook message was wrongly classified as PUSH_RACE_RECOVERED"; fails=1; }
  [ "$(_ledger_count sm/cab-policy-collision PUSH_RACE_EXHAUSTED)" = "0" ] || { echo "FAIL: CAB-policy hook message was wrongly classified as PUSH_RACE_EXHAUSTED -- the exact free-text-collision bug this test guards"; fails=1; }

  # ---- Test 32: (P2) --preflight-only's merge-tree --write-tree call may increase the loose
  # object count (the dangling merge-tree result), but the lock dir, main ref, ledger, and repo
  # cleanliness stay exactly as Test 22 already asserts -- the READ-ONLY guarantee is scoped to
  # working tree/index/branch-refs/lock/ledger specifically, not "no git-internal footprint at
  # all" (see the reframed header comment). ----
  IFS='|' read -r origin32 primary32 <<<"$(_setup_repo 32)"
  git -C "$primary32" worktree add -q "$t/wt32" -b sm/preflight-object-write main
  echo "feature-objwrite" >> "$t/wt32/file.txt"
  git -C "$t/wt32" commit -qam "feature object write"
  sha32="$(git -C "$t/wt32" rev-parse HEAD)"
  # Genuine divergence on a DIFFERENT file, so the merge-tree result is a real, brand-new tree --
  # a merge-tree computed against an origin that never diverged just reuses the feature branch's
  # OWN already-existing tree object, writing nothing new (this is exactly why a naive version of
  # this test, without this divergent commit, saw no object-count change at all).
  echo "origin-side-objwrite" > "$primary32/other-file-32.txt"
  git -C "$primary32" add other-file-32.txt
  git -C "$primary32" commit -qam "origin-side change, different file"
  git -C "$primary32" push -q origin main
  objects_before32="$(git -C "$primary32" count-objects | cut -d' ' -f1)"
  out32="$(_ms --repo "$primary32" --worktree "$t/wt32" --branch sm/preflight-object-write --base main --checked-sha "$sha32" --preflight-only --wait-timeout 5 2>&1)"
  rc32=$?
  [ "$rc32" -eq 8 ] || { echo "FAIL: preflight object-write test expected rc=8, got $rc32: $out32"; fails=1; }
  objects_after32="$(git -C "$primary32" count-objects | cut -d' ' -f1)"
  [ "$objects_after32" -gt "$objects_before32" ] || { echo "FAIL: expected loose object count to increase (the documented merge-tree --write-tree exception) -- got before=$objects_before32 after=$objects_after32; if this now stays equal, the header comment's 2nd exception is stale and should be removed, not left describing behavior that no longer happens"; fails=1; }
  [ -z "$(git -C "$primary32" status --porcelain 2>/dev/null)" ] || { echo "FAIL: preflight left the working tree dirty despite the object-database exception being documented as write-only (no working-tree/index change)"; fails=1; }
  [ ! -e "$primary32/.git/MERGE_HEAD" ] || { echo "FAIL: preflight left MERGE_HEAD despite never running a real merge"; fails=1; }

  # ---- Test 33: (P2) confirms --preflight-only's fetch has fetch's OWN ordinary footprint
  # (.git/FETCH_HEAD written, new objects downloaded) -- documented explicitly after round 4 found
  # this undocumented, using the same independent-clone-advances-origin scenario as the checker's
  # own repro. This is expected, documented behavior, not a defect to chase further. ----
  IFS='|' read -r origin33 primary33 <<<"$(_setup_repo 33)"
  git -C "$primary33" worktree add -q "$t/wt33" -b sm/preflight-fetch-footprint main
  echo "feature-fetchfoot" >> "$t/wt33/file.txt"
  git -C "$t/wt33" commit -qam "feature fetch footprint"
  sha33="$(git -C "$t/wt33" rev-parse HEAD)"
  git clone -q "$primary33" "$t/other-clone33" >/dev/null 2>&1
  git -C "$t/other-clone33" remote set-url origin "$origin33"
  echo "independent-advance-33" > "$t/other-clone33/other-file-33.txt"
  git -C "$t/other-clone33" add other-file-33.txt
  git -C "$t/other-clone33" commit -qam "independent origin advance"
  git -C "$t/other-clone33" push -q origin main
  [ ! -e "$primary33/.git/FETCH_HEAD" ] || { echo "FAIL: test setup invariant broken -- FETCH_HEAD already present before preflight ran"; fails=1; }
  objects_before33="$(git -C "$primary33" count-objects | cut -d' ' -f1)"
  out33="$(_ms --repo "$primary33" --worktree "$t/wt33" --branch sm/preflight-fetch-footprint --base main --checked-sha "$sha33" --preflight-only --wait-timeout 5 2>&1)"
  rc33=$?
  [ "$rc33" -eq 8 ] || { echo "FAIL: preflight fetch-footprint test expected rc=8, got $rc33: $out33"; fails=1; }
  [ -e "$primary33/.git/FETCH_HEAD" ] || { echo "FAIL: expected .git/FETCH_HEAD to exist after preflight's fetch (documented, ordinary fetch footprint)"; fails=1; }
  objects_after33="$(git -C "$primary33" count-objects | cut -d' ' -f1)"
  [ "$objects_after33" -gt "$objects_before33" ] || { echo "FAIL: expected new objects to be downloaded from the independent origin advance"; fails=1; }
  [ -z "$(git -C "$primary33" status --porcelain 2>/dev/null)" ] || { echo "FAIL: preflight's fetch left the working tree dirty"; fails=1; }

  # ---- Test 34: (P1) CRITICAL negative test -- a hook that tries to LITERALLY SPOOF git's own
  # ref-lock-race parenthetical, including a fake full "! [remote rejected] ... (incorrect old
  # value provided)" line, must still be PUSH_FAILED. Verified empirically that git relays even a
  # spoofed line through the "remote: " prefix, and separately, correctly generates its OWN
  # unprefixed summary line with the TRUE reason -- _client_lines_only's job is to only ever look
  # at that second, unspoofable line. ----
  IFS='|' read -r origin34 primary34 <<<"$(_setup_repo 34)"
  cat > "$origin34/hooks/pre-receive" <<'HOOKEOF'
#!/bin/sh
echo "policy denied (incorrect old value provided)" >&2
echo " ! [remote rejected] main -> main (incorrect old value provided)" >&2
exit 1
HOOKEOF
  chmod +x "$origin34/hooks/pre-receive"
  git -C "$primary34" worktree add -q "$t/wt34" -b sm/hook-spoofs-reflock main
  echo "feature-p34" >> "$t/wt34/file.txt"
  git -C "$t/wt34" commit -qam "feature p34"
  sha34="$(git -C "$t/wt34" rev-parse HEAD)"
  out34="$(_ms --repo "$primary34" --worktree "$t/wt34" --branch sm/hook-spoofs-reflock --base main --checked-sha "$sha34" --wait-timeout 5 2>&1)"
  rc34=$?
  [ "$rc34" -eq 4 ] || { echo "FAIL: hook spoofing the ref-lock-race parenthetical expected rc=4, got $rc34: $out34"; fails=1; }
  echo "$out34" | grep -qi "PUSH FAILED" || { echo "FAIL: expected a PUSH FAILED message, got: $out34"; fails=1; }
  [ "$(_ledger_count sm/hook-spoofs-reflock PUSH_FAILED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_FAILED ledger record (hook tried to spoof the ref-lock-race parenthetical)"; fails=1; }
  [ "$(_ledger_count sm/hook-spoofs-reflock PUSH_RACE_RECOVERED)" = "0" ] || { echo "FAIL: spoofed ref-lock-race parenthetical was wrongly classified as PUSH_RACE_RECOVERED"; fails=1; }
  [ "$(_ledger_count sm/hook-spoofs-reflock PUSH_RACE_EXHAUSTED)" = "0" ] || { echo "FAIL: spoofed ref-lock-race parenthetical was wrongly classified as PUSH_RACE_EXHAUSTED -- the exact spoofing bug this test guards"; fails=1; }

  # ---- Test 35: (P1) CRITICAL negative test -- a genuine race on the initial push, followed by
  # an UNRELATED failure (auth/network, matching neither a race signature nor a recognized hook
  # rejection) on the FIRST retry, must stop immediately rather than burning a 3rd, pointless
  # attempt. An earlier revision only escalated on a confirmed hook rejection and silently
  # continued retrying on anything else it couldn't positively classify. ----
  IFS='|' read -r origin35 primary35 <<<"$(_setup_repo 35)"
  git -C "$primary35" worktree add -q "$t/wt35" -b sm/auth-fail-midrace main
  echo "feature-authfail" >> "$t/wt35/file.txt"
  git -C "$t/wt35" commit -qam "feature auth fail"
  sha35="$(git -C "$t/wt35" rev-parse HEAD)"
  fake_git_dir35="$t/fake-git-35"
  mkdir -p "$fake_git_dir35"
  real_git_path35="$(command -v git)"
  counter35="$t/push-counter-35"
  : > "$counter35"
  cat > "$fake_git_dir35/git" <<GITSHIM
#!/usr/bin/env bash
real_git="$real_git_path35"
args=("\$@")
i=0
sub=""
while [ \$i -lt \${#args[@]} ]; do
  case "\${args[\$i]}" in
    -C) i=\$((i+2));;
    *) sub="\${args[\$i]}"; break;;
  esac
done
if [ "\$sub" = "push" ]; then
  n=\$(wc -l < "$counter35" | tr -d ' ')
  echo "attempt" >> "$counter35"
  if [ "\$n" = "0" ]; then
    echo "! [rejected]  main -> main (fetch first)" >&2
    exit 1
  else
    echo "fatal: Authentication failed for '\''origin'\''" >&2
    exit 1
  fi
fi
exec "\$real_git" "\$@"
GITSHIM
  chmod +x "$fake_git_dir35/git"
  out35="$(PATH="$fake_git_dir35:$PATH" _ms --repo "$primary35" --worktree "$t/wt35" --branch sm/auth-fail-midrace --base main --checked-sha "$sha35" --wait-timeout 5 2>&1)"
  rc35=$?
  [ "$rc35" -eq 4 ] || { echo "FAIL: race-then-auth-failure expected rc=4, got $rc35: $out35"; fails=1; }
  attempt_count35="$(wc -l < "$counter35" | tr -d ' ')"
  [ "$attempt_count35" = "2" ] || { echo "FAIL: expected exactly 2 push attempts (initial race + 1 retry that hit the unrelated auth failure), got $attempt_count35 -- an unrelated failure must stop the loop immediately, not burn a pointless 3rd attempt"; fails=1; }
  [ "$(_ledger_count sm/auth-fail-midrace PUSH_RACE_RECOVERED)" = "0" ] || { echo "FAIL: race-then-auth-failure was wrongly classified as PUSH_RACE_RECOVERED"; fails=1; }

  # ---- Test 36: (P1) CRITICAL negative test -- while invocation A is mid-recovery (a real race
  # on its first push, then a slow recovery fetch), a SECOND, concurrent invocation B targeting the
  # SAME --repo must wait for A's lock, never merge/push into that same checkout while A's own
  # recovery is still in progress. An earlier revision released the lock at the top of each retry
  # attempt, letting B complete entirely mid-A's-recovery -- reproduced directly with two real
  # concurrent invocations before this fix (B finished successfully, rc=0, while A was still
  # recovering). The decisive assertion: once both finish, A's own final commit must be an ANCESTOR
  # of B's resulting main -- proof B's merge only happened after A's ENTIRE recovery (including
  # the lock's release) was done, not a race that could have landed B's commit onto a stale base. ----
  IFS='|' read -r origin36 primary36 <<<"$(_setup_repo 36)"
  git -C "$primary36" worktree add -q "$t/wt36a" -b sm/conc-race-a main
  echo "feature-36a" >> "$t/wt36a/file.txt"
  git -C "$t/wt36a" commit -qam "feature 36a"
  sha36a="$(git -C "$t/wt36a" rev-parse HEAD)"
  git -C "$primary36" worktree add -q "$t/wt36b" -b sm/conc-race-b main
  echo "feature-36b" > "$t/wt36b/other-file-36.txt"
  git -C "$t/wt36b" add other-file-36.txt
  git -C "$t/wt36b" commit -qam "feature 36b"
  sha36b="$(git -C "$t/wt36b" rev-parse HEAD)"
  fake_git_dir36="$t/fake-git-36"
  mkdir -p "$fake_git_dir36"
  real_git_path36="$(command -v git)"
  counter36="$t/push-counter-36"
  : > "$counter36"
  cat > "$fake_git_dir36/git" <<GITSHIM
#!/usr/bin/env bash
real_git="$real_git_path36"
args=("\$@")
i=0
sub=""
while [ \$i -lt \${#args[@]} ]; do
  case "\${args[\$i]}" in
    -C) i=\$((i+2));;
    *) sub="\${args[\$i]}"; break;;
  esac
done
if [ "\$sub" = "push" ]; then
  n=\$(wc -l < "$counter36" | tr -d ' ')
  echo "attempt" >> "$counter36"
  if [ "\$n" = "0" ]; then
    echo "! [rejected]  main -> main (fetch first)" >&2
    exit 1
  fi
elif [ "\$sub" = "fetch" ]; then
  sleep 3
fi
exec "\$real_git" "\$@"
GITSHIM
  chmod +x "$fake_git_dir36/git"
  (
    PATH="$fake_git_dir36:$PATH" SM_LOOP_STATE="$SM_LOOP_STATE" SM_MERGE_LEDGER="$SM_MERGE_LEDGER" bash "$MS" \
      --repo "$primary36" --worktree "$t/wt36a" --branch sm/conc-race-a --base main --checked-sha "$sha36a" \
      --wait-timeout 20 > "$t/out36a.log" 2>&1
    echo $? > "$t/rc36a"
  ) &
  pid36a=$!
  sleep 1.2  # let A get past its initial push failure and into the (slow) recovery fetch first
  # THE DECISIVE ASSERTION IS TIMING, NOT FINAL ANCESTRY: A's own recovery merge pulls in whatever
  # landed on origin in the meantime, so even a BROKEN (lock-released-too-early) run can still end
  # up with a plausible-looking, fully-linear final history -- A's recovery logic naturally
  # subsumes an interleaved change once it happens. What it can NEVER do is make B's own git
  # commands finish BEFORE A's lock is actually released, if the lock is genuinely held throughout.
  # Confirmed by direct reproduction: the pre-fix code has B complete in ~0s (races straight in);
  # the fixed code has B block for ~3s (A's full sleep) before proceeding.
  start36b=$(date +%s)
  SM_LOOP_STATE="$SM_LOOP_STATE" SM_MERGE_LEDGER="$SM_MERGE_LEDGER" bash "$MS" \
    --repo "$primary36" --worktree "$t/wt36b" --branch sm/conc-race-b --base main --checked-sha "$sha36b" \
    --wait-timeout 20 > "$t/out36b.log" 2>&1
  rc36b=$?
  end36b=$(date +%s)
  elapsed36b=$((end36b - start36b))
  wait "$pid36a"
  rc36a="$(cat "$t/rc36a")"
  [ "$rc36a" = 0 ] && [ "$rc36b" = 0 ] || { echo "FAIL: concurrent race-recovery test did not both succeed (rc_a=$rc36a rc_b=$rc36b)"; echo "out-a: $(cat "$t/out36a.log")"; echo "out-b: $(cat "$t/out36b.log")"; fails=1; }
  [ "$elapsed36b" -ge 2 ] || { echo "FAIL: B completed in ${elapsed36b}s -- expected B to be BLOCKED on A's lock for close to A's full 3s recovery sleep, not race straight in (serialization violated, the exact bug this test guards)"; fails=1; }
  [ -f "$primary36/file.txt" ] && grep -q "feature-36a" "$primary36/file.txt" || { echo "FAIL: concurrent race-recovery test lost A's change"; fails=1; }
  [ -f "$primary36/other-file-36.txt" ] && grep -q "feature-36b" "$primary36/other-file-36.txt" || { echo "FAIL: concurrent race-recovery test lost B's change"; fails=1; }

  # ---- Test 37: (P1) CRITICAL negative test -- a LOCAL 'pre-push' hook (client-side, runs BEFORE
  # git ever attempts the network-level push at all) whose message happens to say
  # "(incorrect old value provided)" verbatim must still be PUSH_FAILED, never a ref-lock race.
  # Unlike a server-side hook, pre-push's stderr has NO "remote: " relay prefix (or any other
  # marker) at all -- verified empirically -- so _client_lines_only's filter can't help here; the
  # fix is a filesystem-level check (_repo_has_pre_push_hook), not another text pattern. ----
  IFS='|' read -r origin37 primary37 <<<"$(_setup_repo 37)"
  cat > "$primary37/.git/hooks/pre-push" <<'HOOKEOF'
#!/bin/sh
echo "(incorrect old value provided)" >&2
exit 1
HOOKEOF
  chmod +x "$primary37/.git/hooks/pre-push"
  git -C "$primary37" worktree add -q "$t/wt37" -b sm/local-prepush-reflock main
  echo "feature-p37" >> "$t/wt37/file.txt"
  git -C "$t/wt37" commit -qam "feature p37"
  sha37="$(git -C "$t/wt37" rev-parse HEAD)"
  out37="$(_ms --repo "$primary37" --worktree "$t/wt37" --branch sm/local-prepush-reflock --base main --checked-sha "$sha37" --wait-timeout 5 2>&1)"
  rc37=$?
  [ "$rc37" -eq 4 ] || { echo "FAIL: local pre-push hook spoofing the ref-lock-race parenthetical expected rc=4, got $rc37: $out37"; fails=1; }
  echo "$out37" | grep -qi "PUSH FAILED" || { echo "FAIL: expected a PUSH FAILED message, got: $out37"; fails=1; }
  [ "$(_ledger_count sm/local-prepush-reflock PUSH_FAILED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_FAILED ledger record (local pre-push hook, no server contact at all)"; fails=1; }
  [ "$(_ledger_count sm/local-prepush-reflock PUSH_RACE_RECOVERED)" = "0" ] || { echo "FAIL: local pre-push hook rejection was wrongly classified as PUSH_RACE_RECOVERED"; fails=1; }
  [ "$(_ledger_count sm/local-prepush-reflock PUSH_RACE_EXHAUSTED)" = "0" ] || { echo "FAIL: local pre-push hook rejection was wrongly classified as PUSH_RACE_EXHAUSTED -- the exact local-hook spoofing bug this test guards"; fails=1; }

  # ---- Test 38: (P1) CRITICAL negative test -- the SAME local 'pre-push' hook gap, but for the
  # PLAIN keyword race check (_is_race), not the ref-lock parenthetical -- a hook message
  # containing an ordinary race-shaped word ("behind") with none of _is_hook_rejection's own
  # keywords, and no "remote: " framing, must also stay PUSH_FAILED. This is a distinct sibling
  # bug from Test 37 (different classifier function), independently confirmed real before fixing:
  # a bare "_repo_has_pre_push_hook" guard on _is_ref_lock_race alone did NOT close this one. ----
  IFS='|' read -r origin38 primary38 <<<"$(_setup_repo 38)"
  cat > "$primary38/.git/hooks/pre-push" <<'HOOKEOF'
#!/bin/sh
echo "your branch appears behind our compliance baseline, contact IT" >&2
exit 1
HOOKEOF
  chmod +x "$primary38/.git/hooks/pre-push"
  git -C "$primary38" worktree add -q "$t/wt38" -b sm/local-prepush-keyword main
  echo "feature-p38" >> "$t/wt38/file.txt"
  git -C "$t/wt38" commit -qam "feature p38"
  sha38="$(git -C "$t/wt38" rev-parse HEAD)"
  out38="$(_ms --repo "$primary38" --worktree "$t/wt38" --branch sm/local-prepush-keyword --base main --checked-sha "$sha38" --wait-timeout 5 2>&1)"
  rc38=$?
  [ "$rc38" -eq 4 ] || { echo "FAIL: local pre-push hook keyword collision expected rc=4, got $rc38: $out38"; fails=1; }
  echo "$out38" | grep -qi "PUSH FAILED" || { echo "FAIL: expected a PUSH FAILED message, got: $out38"; fails=1; }
  [ "$(_ledger_count sm/local-prepush-keyword PUSH_FAILED)" = "1" ] || { echo "FAIL: expected exactly one PUSH_FAILED ledger record (local pre-push hook, plain-keyword collision)"; fails=1; }
  [ "$(_ledger_count sm/local-prepush-keyword PUSH_RACE_RECOVERED)" = "0" ] || { echo "FAIL: local pre-push hook keyword collision was wrongly classified as PUSH_RACE_RECOVERED"; fails=1; }
  [ "$(_ledger_count sm/local-prepush-keyword PUSH_RACE_EXHAUSTED)" = "0" ] || { echo "FAIL: local pre-push hook keyword collision was wrongly classified as PUSH_RACE_EXHAUSTED -- the exact sibling spoofing bug this test guards"; fails=1; }

  rm -rf "$t"
  trap - EXIT
  [ "$fails" = 0 ] && echo ok
  exit "$fails"
fi

# ============================== argument parsing ==============================
repo="" worktree="" branch="" base="main" checked_sha="" test_cmd="" message="" wait_timeout=300 preflight_only=""
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
    --preflight-only) preflight_only=1; shift;;
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

# --preflight-only has its own dedicated execution path and cannot be combined with other options
if [ "$preflight_only" = "1" ]; then
  if [ -n "$test_cmd" ] || [ -n "$message" ]; then
    echo "--preflight-only is read-only and cannot be combined with --test or --message" >&2
    _usage
    exit 2
  fi
fi

# Closes a real command-injection concern: reject anything that isn't a plain branch-name charset
# before it ever reaches an unquoted-adjacent git invocation.
case "$branch" in
  *[!a-zA-Z0-9_/-]*) echo "invalid --branch: $branch (allowed charset: [a-zA-Z0-9_/-])" >&2; exit 2;;
  '') echo "invalid --branch: empty" >&2; exit 2;;
esac

[ -d "$repo" ] || { echo "--repo $repo is not a directory" >&2; exit 2; }
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "--repo $repo is not a git working tree" >&2; exit 2; }
[ -d "$worktree" ] || { echo "--worktree $worktree is not a directory" >&2; exit 2; }
git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "--worktree $worktree is not a git working tree" >&2; exit 2; }

# --worktree must be an ACTUAL linked worktree of --repo (sharing the same git-common-dir, i.e. the
# same underlying object database via `git worktree add`), not merely a separate, independent clone of
# the same repository. Commit SHAs are portable across clones, so an independent clone could pass
# verify-gate.sh's own --checked-sha check while resolving --base entirely within its own, possibly
# STALE, local refs -- verify-gate.sh would correctly report a clean pass relative to that clone's own
# (stale) view, while the actual merge lands into --repo's real, newer state, silently bypassing the
# whole 'review is fresh relative to what actually gets merged' guarantee. git-common-dir is the one
# thing that's true for every genuine linked worktree and false for an independent clone.
repo_common_dir="$(cd "$repo" 2>/dev/null && cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)"
worktree_common_dir="$(cd "$worktree" 2>/dev/null && cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)"
if [ -z "$repo_common_dir" ] || [ -z "$worktree_common_dir" ] || [ "$repo_common_dir" != "$worktree_common_dir" ]; then
  echo "--worktree $worktree is not a linked worktree of --repo $repo (git-common-dir mismatch: repo='${repo_common_dir:-<unresolvable>}' worktree='${worktree_common_dir:-<unresolvable>}') -- refusing. --worktree must be created via 'git worktree add' against this exact --repo, not an independent clone (an independent clone can pass verify-gate.sh's own checks against its own, possibly stale, local refs while the actual merge lands somewhere entirely different)." >&2
  exit 2
fi

# The actual merge/push happens in $repo, so $repo must actually have $base checked out --
# otherwise the merge would silently land on whatever branch $repo happens to be on.
repo_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
if [ "$repo_branch" != "$base" ]; then
  echo "--repo $repo is checked out on '$repo_branch', not --base '$base' -- refusing (merge would land on the wrong branch)" >&2
  exit 2
fi

[ -n "$message" ] || message="Merge $branch"

# ============================== preflight-only path (no working-tree/branch-ref/lock/ledger side effects -- fetch/merge-tree's own ordinary git-internal footprint is out of scope of that guarantee, see header comment above) ==============================
if [ "$preflight_only" = "1" ]; then
  # Same invariant the normal merge path enforces (see the identical check later in this file,
  # around the "Bug A fix" comment) -- --branch is the thing a merge would actually act on, so it
  # must resolve to EXACTLY --checked-sha. Without this, a caller could pass a STALE --checked-sha
  # (an old review) alongside a --branch that has since moved forward with new, unreviewed commits
  # -- preflight would check the old, reviewed SHA for conflicts and report "clean" while saying
  # nothing about the branch's actual current tip. Checked here too (not just relied upon at merge
  # time) because --preflight-only is read-only-by-design and never reaches that later check at all.
  branch_sha="$(git -C "$repo" rev-parse --verify "${branch}^{commit}" 2>/dev/null || echo "")"
  if [ -z "$branch_sha" ] || [ "$branch_sha" != "$checked_sha" ]; then
    echo "ERROR: --branch '$branch' resolves to '${branch_sha:-<does not resolve>}', which does not match --checked-sha '$checked_sha' -- --preflight-only cannot check a SHA that isn't --branch's own current tip." >&2
    exit 7
  fi
  # Validate git supports --write-tree (git merge-tree requires it)
  git merge-tree --help >/dev/null 2>&1 || { echo "UNSUPPORTED: git merge-tree --write-tree is not supported (requires git >= 2.38)" >&2; exit 7; }
  # Fetch origin to get current state of --base. NOTE: like any 'git fetch', this writes
  # .git/FETCH_HEAD, updates refs/remotes/origin/$base, and downloads any new objects into $repo's
  # object database -- the ordinary footprint of fetch itself, not something this script adds on
  # top. It does not touch $repo's working tree, index, HEAD/branch refs, lock, or ledger, and
  # every exit path below (clean, conflict, or unsupported) is otherwise identical to a real
  # read-only check of those five things. A caller that needs a fetch with literally zero writes
  # of any kind should use 'git ls-remote' up front themselves and pass its own base.
  if ! git -C "$repo" fetch origin "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null 2>&1; then
    echo "ERROR: failed to fetch origin/$base (check network/permissions)" >&2
    exit 7
  fi
  # Get the current SHA of origin/<base> (the actual current state)
  origin_base_sha="$(git -C "$repo" rev-parse --verify "origin/$base^{commit}" 2>/dev/null || echo "")"
  if [ -z "$origin_base_sha" ]; then
    echo "ERROR: origin/$base does not resolve to a commit (fetch may be stale or branch doesn't exist)" >&2
    exit 7
  fi
  # Run git merge-tree --write-tree to check for conflicts
  # Exit 0 = clean, exit 1 = conflict, exit other = unsupported/error
  set +e
  merged_tree_sha="$(git -C "$repo" merge-tree --write-tree "$origin_base_sha" "$checked_sha" 2>&1)"
  merge_tree_rc=$?
  set -e
  if [ "$merge_tree_rc" -ne 0 ]; then
    if [ "$merge_tree_rc" -eq 1 ]; then
      # Conflict detected
      echo "CONFLICT: --preflight-only detected merge conflict between origin/$base ($origin_base_sha) and --branch '$branch' ($checked_sha)." >&2
      echo "ACTION: The maker must merge origin/$base INTO the branch itself (never rebase), then re-run checker+verify-gate, then re-issue the hold bound to the new SHA. bin/hold.py's existing --sha mismatch rejection already enforces this rebinding." >&2
      exit 6
    else
      # Non-1 exit code = unsupported or other error
      echo "UNSUPPORTED: git merge-tree --write-tree failed with exit code $merge_tree_rc (git may not support --write-tree)" >&2
      exit 7
    fi
  fi
  # Clean path: exit 8 with informational message
  echo "PREFLIGHT OK: --preflight-only confirms no merge conflict (clean merge)." >&2
  exit 8
fi

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
repo_dirty="$(
  lock_excl="$(_repo_relative_path "$repo" "$LOCK_DIR")"
  ledger_excl="$(_repo_relative_path "$repo" "$LEDGER")"
  excl_args=()
  [ -n "$lock_excl" ] && excl_args+=(":(exclude,literal)$lock_excl")
  [ -n "$ledger_excl" ] && excl_args+=(":(exclude,literal)$ledger_excl")
  git -C "$repo" status --porcelain -- . "${excl_args[@]+"${excl_args[@]}"}" 2>/dev/null
)"
if [ -n "$repo_dirty" ]; then
  _release_lock
  echo "ERROR: $repo is not in a clean, mergeable state (uncommitted changes present that this invocation did not create) -- refusing to touch it. A human must investigate $repo directly before this can retry." >&2
  printf '%s\n' "$repo_dirty" >&2
  exit 2
fi

merge_output="$(git -C "$repo" merge --no-ff "$branch" -m "$message" 2>&1)"
merge_rc=$?
if [ "$merge_rc" -ne 0 ]; then
  # A failed 'git merge' does NOT always mean a genuine content conflict -- it can also fail for reasons
  # that never even attempt a real three-way merge, most commonly a repo-configured 'pre-merge-commit'
  # hook rejecting the merge by policy (sign-off requirements, commit-message linting, etc; a real,
  # legitimate mechanism). 'git ls-files -u' listing unmerged paths is the ground truth for whether an
  # actual content conflict occurred; if it's empty, git refused before ever writing conflicted index
  # state, and this must be classified differently so a human/dispatcher reading the ledger reaches for
  # the right remediation (fix the policy issue, not resolve a conflict that never existed).
  unmerged_paths="$(git -C "$repo" ls-files -u 2>/dev/null)"
  git -C "$repo" merge --abort >/dev/null 2>&1 || true
  _release_lock
  if [ -n "$unmerged_paths" ]; then
    echo "MERGE CONFLICT merging '$branch' into '$base' in $repo (aborted, $repo left unchanged):" >&2
    printf '%s\n' "$merge_output" >&2
    _append_ledger_or_warn MERGE_CONFLICT ""
  else
    echo "MERGE REJECTED merging '$branch' into '$base' in $repo -- git refused before any real content conflict occurred (no unmerged paths; likely a pre-merge-commit hook or similar policy check). Aborted, $repo left unchanged. git's own output:" >&2
    printf '%s\n' "$merge_output" >&2
    _append_ledger_or_warn MERGE_REJECTED ""
  fi
  exit 3
fi

merged_sha="$(git -C "$repo" rev-parse HEAD)"

# P1: bounded push-race recovery with exact race-signature regex matching
# Run push with LC_ALL=C to ensure English-language stderr for regex matching
push_output=$(LC_ALL=C git -C "$repo" push origin "$base" 2>&1)
push_rc=$?
if [ "$push_rc" -ne 0 ]; then
  # Classify the failure using bash's own '=~' (no subprocess, no pipe -- 'echo ... | grep -q'
  # lets grep exit the instant it matches, which can SIGPIPE-kill the left-hand producer under
  # 'set -o pipefail' (line 44) for a large enough push_output, e.g. a verbose hook dumping lots of
  # diagnostic text before its actual rejection line -- this would silently misreport a real
  # PUSH_FAILED/hook rejection as an unrelated failure. '=~' has no producer process to kill.
  #
  # REF-LOCK RACE CHECK RUNS FIRST, WITH ABSOLUTE PRIORITY over the hook check. A genuine
  # CONCURRENT server-side ref-transaction race (two pushes landing on the receiving end at
  # nearly the same instant) is ALSO relayed with "remote: "/"[remote rejected]" framing --
  # verified empirically with two real concurrent pushes against a bare repo -- so the hook
  # check below cannot be trusted to run first here.
  #
  # Matches ONLY the "(incorrect old value provided)" parenthetical reason, and ONLY when it
  # appears on a line that is NOT itself a relayed "remote: <text>" line. An earlier revision
  # matched the literal words "cannot lock ref" anywhere in the raw output (fooled by a hook
  # message containing that exact phrase as ordinary policy English); the NEXT revision narrowed
  # to the "(incorrect old value provided)" parenthetical but still searched the whole raw blob,
  # which a SERVER-SIDE hook can ALSO spoof by printing that exact string itself -- verified
  # empirically: a server-side hook's own attempt to print "(incorrect old value provided)" (or
  # even a full fake "! [remote rejected] ... (incorrect old value provided)" line) still gets
  # git's normal "remote: " relay prefix, and git's REAL client-generated summary line (never
  # "remote: "-prefixed) appears as a SEPARATE line alongside it. Filtering out every
  # "remote: "-prefixed line closes THAT class -- but a LOCAL 'pre-push' hook runs entirely
  # client-side, BEFORE git ever attempts the network-level push at all, so its stderr has no
  # "remote: " relay prefix (or ANY other distinguishing marker) whatsoever: verified empirically
  # that its output is indistinguishable in shape from git's own client-generated text. Since
  # 'pre-push' rejecting means the push never reached the server (the genuine ref-CAS failure this
  # check exists to recognize is architecturally impossible to also have occurred in that same
  # invocation), the correct fix is a filesystem-level check, not another text pattern: if $repo
  # has an executable pre-push hook installed (respecting core.hooksPath, not just the default
  # .git/hooks/ location), never trust ANY text match here -- fall through to the hook-rejection/
  # plain-race checks below instead, which report PUSH_FAILED rather than misclassifying.
  _repo_has_pre_push_hook() {
    local hooks_dir
    hooks_dir="$(git -C "$repo" rev-parse --git-path hooks 2>/dev/null)" || return 1
    case "$hooks_dir" in
      /*) : ;;
      *) hooks_dir="$repo/$hooks_dir" ;;
    esac
    [ -x "$hooks_dir/pre-push" ]
  }
  _client_lines_only() {
    local out="" line
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "remote: "*) ;;  # hook/server relay -- never trust this line's content structurally
        *) out+="$line"$'\n';;
      esac
    done <<< "$1"
    printf '%s' "$out"
  }
  _is_ref_lock_race() {
    _repo_has_pre_push_hook && return 1
    local client_only
    client_only="$(_client_lines_only "$1")"
    case "$client_only" in
      *"(incorrect old value provided)"*) return 0;;
    esac
    return 1
  }
  # HOOK CHECK RUNS SECOND, WITH PRIORITY over the plain race-keyword check (but never over the
  # ref-lock race above) -- not merely "excluded from" the race regex. A hook/protected-branch
  # rejection message is admin-authored, arbitrary text, and can legitimately contain race-shaped
  # words (e.g. "rejected because branch is behind policy") -- classifying by race-keyword-presence
  # alone would retry a permanent policy rejection forever, hiding the real failure. Git's own
  # rejection framing is a much more reliable, non-keyword discriminator: ANY server-side rejection
  # (a real remote hook, or a local bare-repo pre-receive hook used by this file's own selfcheck
  # fixtures) is relayed to the client with a literal "remote: " line prefix and shows "[remote
  # rejected]" in the summary line -- wording git itself controls, not something a hook author can
  # spoof through their own message text. A genuine local, client-side non-fast-forward rejection
  # (the only thing recovery should ever retry via THIS check) has neither: plain "[rejected]" with
  # no "remote" inside the brackets, and no "remote: " lines at all (verified empirically: a real
  # hook rejection vs. a real fast-forward race produce exactly this observable difference on this
  # git version).
  _is_hook_rejection() {
    case "$1" in
      *"remote: "*|*"[remote rejected]"*) return 0;;
    esac
    local re='(pre-receive|pre-update|updatehook|hook rejection|protected branch)'
    local rc
    shopt -s nocasematch
    [[ "$1" =~ $re ]]; rc=$?
    shopt -u nocasematch
    return "$rc"
  }
  # SAME '_repo_has_pre_push_hook' guard as '_is_ref_lock_race' above, for the SAME reason via a
  # DIFFERENT sibling path: a LOCAL 'pre-push' hook's arbitrary message can ALSO coincidentally
  # contain one of the plain race keywords below (e.g. "your branch appears behind our compliance
  # baseline") -- verified empirically -- and unlike a server-side hook, this message has neither
  # "remote: " framing nor any of _is_hook_rejection's literal keywords for that check to catch
  # first, so it fell straight through to this bare keyword match. A local pre-push hook's stderr
  # is structurally indistinguishable from git's own client-generated race text (no relay prefix,
  # no boundary marker of any kind), so once a pre-push hook is known to be installed, no text
  # pattern here can be trusted -- this is the honest, conservative fix, not another point-patch.
  _is_race() {
    _repo_has_pre_push_hook && return 1
    local re='(behind|fast[- ]?forward|stale info|fetch first|contains work that you do not have)'
    local rc
    shopt -s nocasematch
    [[ "$1" =~ $re ]]; rc=$?
    shopt -u nocasematch
    return "$rc"
  }

  if _is_ref_lock_race "$push_output" || { ! _is_hook_rejection "$push_output" && _is_race "$push_output"; }; then
    # Genuine race detected! Attempt bounded recovery. The initial push above already counts as
    # attempt 1 of 3 total -- the loop below performs attempts 2 and 3 (2 more real push calls),
    # never a 4th.
    echo "PUSH RACE (attempt 1/3): push failed, attempting race recovery..." >&2

    # The lock stays held through the ENTIRE recovery sequence below (fetch, merge, retry-push,
    # every attempt) -- same as the normal merge+push path already holds it through both. An
    # earlier revision released the lock at the top of each retry iteration, on the theory of not
    # blocking other waiters during network I/O -- but $repo's WORKING TREE/INDEX/HEAD is what the
    # lock actually protects, and recovery's own 'git merge' mutates exactly that, still inside
    # $repo, for the full duration of every retry attempt. Releasing it there let a second,
    # concurrent invocation targeting the SAME --repo acquire the lock and merge/push into that
    # same checkout WHILE this invocation's recovery was still in progress -- reproduced directly
    # with two real concurrent invocations: the second completed successfully mid-recovery of the
    # first, defeating the entire "serialize concurrent merges to the same primary checkout"
    # purpose this script exists for. Every _release_lock call elsewhere in this file is
    # immediately followed by exit; this loop's own exits (below) are no different.
    for attempt in 2 3; do
      echo "PUSH RACE (attempt $attempt/3): push failed, attempting race recovery..." >&2

      # git fetch origin (only touches remote-tracking refs, never working tree)
      if ! git -C "$repo" fetch origin >/dev/null 2>&1; then
        echo "PUSH RACE EXHAUSTED: failed to fetch origin before attempt $attempt" >&2
        _append_ledger_or_warn PUSH_RACE_EXHAUSTED ""
        exit 4
      fi

      # git merge origin/<base> INTO $repo (SECOND merge, separate from the one that already landed)
      # Give this recovery merge commit a distinctive message
      recovery_msg="merge-sequencer: race recovery (attempt $attempt/3)"
      # --no-ff: without it, a merge that would otherwise fast-forward (or find nothing new at all,
      # e.g. in a test fixture that fakes a push failure without origin actually advancing) creates
      # NO commit at all, silently defeating the point of the distinctive per-attempt message --
      # the whole reason this recovery is auditable via git log alone, not just the ledger.
      merge_recovery_out=$(git -C "$repo" merge --no-ff "origin/$base" -m "$recovery_msg" 2>&1)
      merge_recovery_rc=$?
      if [ "$merge_recovery_rc" -ne 0 ]; then
        # Recovery merge itself conflicted!
        git -C "$repo" merge --abort >/dev/null 2>&1 || true
        echo "PUSH RACE EXHAUSTED: recovery merge conflicted on attempt $attempt" >&2
        echo "NOTE: the local merge commit $merged_sha for '$branch' is still present on '$base' in $repo" >&2
        _append_ledger_or_warn PUSH_RACE_EXHAUSTED ""
        exit 4
      fi

      # Retry push (this IS attempt $attempt -- the loop variable already counts it)
      push_output=$(LC_ALL=C git -C "$repo" push origin "$base" 2>&1)
      push_rc=$?
      if [ "$push_rc" -eq 0 ]; then
        # Recovery succeeded!
        final_merged_sha="$(git -C "$repo" rev-parse HEAD)"
        _append_ledger_or_warn PUSH_RACE_RECOVERED "$final_merged_sha"
        echo "merged $branch -> $base as $final_merged_sha (pushed to origin after race recovery)" >&2
        exit 0
      fi

      # This attempt failed too -- ESCALATE UNLESS the failure is STILL POSITIVELY CONFIRMED to be
      # the same kind of race, using the exact same classification as the initial push above. An
      # earlier revision of this check only escalated on a confirmed hook rejection and silently
      # continued retrying on anything else -- which meant a completely unrelated failure mid-loop
      # (an expired credential: "fatal: Authentication failed for origin", a transport/network
      # error, or anything else neither a race nor a recognized hook signature) fell through to
      # "keep retrying" by default, burning an attempt and ultimately reporting PUSH_RACE_EXHAUSTED
      # for a failure that was never a race at all. Fail closed instead: only continue the loop
      # when the failure is affirmatively still race-shaped.
      if _is_ref_lock_race "$push_output" || { ! _is_hook_rejection "$push_output" && _is_race "$push_output"; }; then
        continue  # still race-shaped -- proceed to the next attempt (or exhaust below)
      fi
      echo "PUSH RACE EXHAUSTED: recovery attempt $attempt/3 failed for a reason that is no longer race-shaped (hook/protected-branch rejection, or an unrelated failure such as auth/network)" >&2
      echo "NOTE: the local merge commit $merged_sha for '$branch' is still present on '$base' in $repo" >&2
      printf '%s\n' "$push_output" >&2
      _append_ledger_or_warn PUSH_RACE_EXHAUSTED ""
      exit 4
    done

    # All 3 attempts (1 initial + 2 retries) exhausted
    _release_lock
    echo "PUSH RACE EXHAUSTED: all 3 attempts failed" >&2
    echo "NOTE: the local merge commit $merged_sha for '$branch' already landed on '$base' in $repo -- it was NOT reverted" >&2
    _append_ledger_or_warn PUSH_RACE_EXHAUSTED ""
    exit 4
  else
    # Not a race (or a hook/protected-branch rejection, which always takes priority) -> PUSH_FAILED, no retry
    _release_lock
    echo "PUSH FAILED pushing '$base' to origin from $repo:" >&2
    printf '%s\n' "$push_output" >&2
    echo "NOTE: the local merge commit $merged_sha for '$branch' already landed on '$base' in $repo -- it was NOT reverted. Only the push to origin needs a manual retry, e.g.: git -C $repo push origin $base" >&2
    _append_ledger_or_warn PUSH_FAILED ""
    exit 4
  fi
fi

_append_ledger_or_warn SUCCESS "$merged_sha"
_release_lock
echo "merged $branch -> $base as $merged_sha (pushed to origin)"
exit 0
