#!/usr/bin/env bash
# close-out.sh -- post-integration teardown for a finished maker/checker task.
#
# The SOP rule: after authorized integration, owned worktrees, branches, and
# claims are torn down. This script makes that rule mechanical and fail-closed
# so it holds no matter who ran the merge (supervisor or operator):
#   1. REFUSE if the task branch is not merged into the integration base.
#   2. Remove the task worktree (herdr workspace first so panes close, then
#      plain git worktree remove as fallback; never --force over a dirty tree).
#   3. Delete the merged task branch (plain -d, which refuses unmerged tips).
#   4. Release the task claim with its real token (claim-ledger refuses fakes).
# Nothing is destroyed before its merged/clean state is verified. Ledger records
# carry the audit weight; verdict files in the worktree are point-in-time
# evidence, not a reason to defer teardown.
#
#   close-out.sh --repo PATH --task-id ID --owner OWNER --token TOKEN
#                [--branch NAME] [--base REF] [--worktree PATH]
#                [--selfcheck]
# Exit 0 = everything torn down (or nothing left to tear down); exit 1 = REFUSE
# with every failing condition listed (mirrors verify-gate.sh reporting).

set -euo pipefail

# Absolute path to this script (selfcheck re-invokes it from a temp cwd).
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

repo=""
task_id=""
owner=""
token=""
branch=""
base="origin/main"
worktree=""
selfcheck=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; repo="$2"; shift 2;;
        --task-id) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; task_id="$2"; shift 2;;
        --owner) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; owner="$2"; shift 2;;
        --token) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; token="$2"; shift 2;;
        --branch) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; branch="$2"; shift 2;;
        --base) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; base="$2"; shift 2;;
        --worktree) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }; worktree="$2"; shift 2;;
        --selfcheck) selfcheck=1; shift;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

failures=""
refuse() { failures="${failures}  - $1\n"; }

# --- selfcheck: hermetic fixture repo, proves fail-closed behavior -----------
if [ "$selfcheck" = "1" ]; then
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/close-out-selfcheck.XXXXXX")
    trap 'rm -rf "$TMP"' EXIT
    cd "$TMP"
    git init -q base && cd base && git config user.email t@t && git config user.name t && git config receive.denyCurrentBranch ignore
    echo one > f && git add f && git commit -qm one
    cd "$TMP" && git clone -q base repo && cd repo
    git config user.email t@t && git config user.name t
    DB=$(git symbolic-ref --short HEAD)
    # merged branch + clean worktree -> teardown succeeds
    git checkout -qb sm/ok-task && echo two > g && git add g && git commit -qm two
    git push -q origin sm/ok-task
    git checkout -q "$DB" && git merge -q sm/ok-task && git push -q origin "$DB"
    git worktree add -q ../sm-ok-task sm/ok-task
    CL="$(dirname "$SCRIPT_PATH")/claim-ledger.py"
    python3 "$CL" claim --task-id ok-task --owner t >/dev/null 2>&1
    CTOK=$(python3 "$CL" token --task-id ok-task 2>/dev/null)
    [ -n "$CTOK" ] || { echo "SELFTEST FAIL: token subcommand returned nothing"; exit 1; }
    # wrong token: branch+worktree torn down, claim release REFUSED
    out=$(bash "$SCRIPT_PATH" --repo "$TMP/repo" --task-id ok-task --owner t --token wrong 2>&1) || true
    echo "$out" | grep -q "branch sm/ok-task deleted" || { echo "SELFTEST FAIL: merged branch not deleted"; echo "$out"; exit 1; }
    [ ! -d "$TMP/sm-ok-task" ] || { echo "SELFTEST FAIL: worktree dir still exists"; exit 1; }
    echo "$out" | grep -q "claim ok-task release failed" || { echo "SELFTEST FAIL: wrong token accepted"; echo "$out"; exit 1; }
    # right token: claim released, exit 0
    out=$(bash "$SCRIPT_PATH" --repo "$TMP/repo" --task-id ok-task --owner t --token "$CTOK" 2>&1) || { echo "SELFTEST FAIL: clean close-out nonzero"; echo "$out"; exit 1; }
    echo "$out" | grep -q "claim ok-task released" || { echo "SELFTEST FAIL: right token not released"; echo "$out"; exit 1; }
    # unmerged branch -> REFUSE, branch/worktree/claim all survive
    git checkout -qb sm/wip-task && echo three > h && git add h && git commit -qm three
    git checkout -q "$DB"
    git worktree add -q ../sm-wip-task sm/wip-task
    set +e
    out=$(bash "$SCRIPT_PATH" --repo "$TMP/repo" --task-id wip-task --owner t --token t 2>&1); rc=$?
    set -e
    [ "$rc" -ne 0 ] || { echo "SELFTEST FAIL: unmerged branch was not refused"; exit 1; }
    echo "$out" | grep -q "REFUSE" || { echo "SELFTEST FAIL: no REFUSE on unmerged"; exit 1; }
    echo "$out" | grep -q "claim wip-task: kept (branch unmerged)" || { echo "SELFTEST FAIL: claim released or missing on unmerged"; echo "$out"; exit 1; }
    git show-ref --verify --quiet refs/heads/sm/wip-task || { echo "SELFTEST FAIL: unmerged branch destroyed"; exit 1; }
    [ -d "$TMP/sm-wip-task" ] || { echo "SELFTEST FAIL: unmerged worktree destroyed"; exit 1; }
    # dirty worktree -> REFUSE destruction, branch handling still reported
    echo dirty >> "$TMP/sm-wip-task/h" || true
    out=$(bash "$SCRIPT_PATH" --repo "$TMP/repo" --task-id wip-task --owner t --token t 2>&1) || true
    echo "$out" | grep -q "dirty" || { echo "SELFTEST FAIL: dirty worktree removed or unreported"; exit 1; }
    echo "ok"
    exit 0
fi

# --- arg validation ----------------------------------------------------------
[ -n "$repo" ] || { echo "--repo is required" >&2; exit 2; }
[ -n "$task_id" ] || { echo "--task-id is required" >&2; exit 2; }
[ -n "$owner" ] || { echo "--owner is required" >&2; exit 2; }
[ -n "$token" ] || { echo "--token is required" >&2; exit 2; }
[ -d "$repo/.git" ] || [ -d "$repo" ] || { echo "repo not found: $repo" >&2; exit 2; }
[ -z "$branch" ] && branch="sm/${task_id}"

cd "$repo"
git fetch -q origin 2>/dev/null || echo "note: could not fetch origin (continuing with local refs)"

# --- step 1: branch merged? ---------------------------------------------------
branch_exists=0
git show-ref --verify --quiet "refs/heads/${branch}" && branch_exists=1
merged=1
if [ "$branch_exists" = "1" ]; then
    if ! git merge-base --is-ancestor "$branch" "$base" 2>/dev/null; then
        merged=0
        refuse "branch ${branch} is not merged into ${base} -- refusing teardown (merge it or delete it deliberately)"
    fi
else
    echo "branch ${branch}: not present (already gone)"
fi

# --- step 2: worktree ----------------------------------------------------------
# Discover the worktree for this branch (or honor --worktree). herdr-managed
# checkouts are removed via `herdr worktree remove` so panes close with them.
wt_path="$worktree"
if [ -z "$wt_path" ] && [ "$branch_exists" = "1" ]; then
    wt_path=$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/${branch}" '
        /^worktree / { wt = substr($0, 10) }
        /^branch / { if ($2 == b) print wt }' | head -1)
fi
if [ -n "$wt_path" ] && [ -d "$wt_path" ]; then
    if [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then
        refuse "worktree ${wt_path} is dirty -- refusing removal (bank or discard the diff first)"
    elif [ "$merged" = "1" ]; then
        ws_id=$(herdr workspace list 2>/dev/null | python3 -c "
import sys, json
try:
    o = json.load(sys.stdin)
    for w in o.get('result', {}).get('workspaces', []):
        if (w.get('worktree') or {}).get('checkout_path') == '$wt_path':
            print(w.get('workspace_id')); break
except Exception:
    pass" 2>/dev/null || true)
        if [ -n "$ws_id" ]; then
            if herdr worktree remove --workspace "$ws_id" >/dev/null 2>&1; then
                echo "worktree ${wt_path}: removed via herdr workspace ${ws_id} (panes closed)"
            else
                refuse "herdr worktree remove --workspace ${ws_id} failed -- falling back refused for safety"
            fi
        else
            if git worktree remove "$wt_path" >/dev/null 2>&1; then
                echo "worktree ${wt_path}: removed"
            else
                refuse "git worktree remove ${wt_path} failed (no herdr workspace found)"
            fi
        fi
    else
        echo "worktree ${wt_path}: kept (branch unmerged)"
    fi
else
    echo "worktree: none present"
fi

# --- step 3: branch deletion ---------------------------------------------------
if [ "$branch_exists" = "1" ]; then
    if [ "$merged" = "1" ]; then
        if git branch -d "$branch" >/dev/null 2>&1; then
            echo "branch ${branch} deleted"
        else
            refuse "git branch -d ${branch} failed"
        fi
    else
        echo "branch ${branch}: kept (unmerged)"
    fi
fi

# --- step 4: claim release ------------------------------------------------------
# claim-ledger.py ships next to this script (harness repo) but resolves the
# ledger per the target repo's git-common-dir, so run it from the repo cwd.
# An unmerged branch keeps the claim open: the task is still owned work.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$merged" = "0" ]; then
    echo "claim ${task_id}: kept (branch unmerged)"
elif python3 "$SCRIPT_DIR/claim-ledger.py" release --task-id "$task_id" --owner "$owner" --token "$token" >/dev/null 2>&1; then
    echo "claim ${task_id} released"
else
    # already-released or wrong token: distinguish instead of failing blind
    if python3 "$SCRIPT_DIR/claim-ledger.py" status 2>/dev/null | grep -q "^\[${task_id}\]"; then
        refuse "claim ${task_id} release failed (token mismatch? steal only with a human reason)"
    else
        echo "claim ${task_id}: not open (already released or never claimed)"
    fi
fi

# --- verdict ---------------------------------------------------------------------
if [ -n "$failures" ]; then
    echo "REFUSE:" >&2
    printf "$failures" >&2
    exit 1
fi
echo "close-out complete: ${task_id} (branch ${branch}, base ${base})"
