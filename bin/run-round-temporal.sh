#!/usr/bin/env bash
# run-round-temporal.sh -- OPT-IN alternate engine for ONE maker+checker round: routes it through the
# proven external Temporal plan-bridge prototype (a real headless `claude` maker activity + a real
# cross-model `pi` checker activity, both durable Temporal activities) instead of secondmate's direct
# herdr-pane maker/checker path. Zero behavior change to any other secondmate script -- this is the
# only call site, and nothing else in bin/ references it.
#
#   run-round-temporal.sh round \
#     --repo PATH                      (required; real worktree; must be clean before starting)
#     --maker-prompt-file F | --maker-prompt TEXT   (required, one of)
#     --checker-goal TEXT              (required)
#     --goal TEXT                      (default: --checker-goal's text)
#     [--criteria TEXT]
#     [--round N]                      (default 1)
#     [--prior-verdict-file F]         (spliced into the checker step's goal text)
#     [--bridge-dir PATH]              (default /Users/eshwar.vijay/coupa/temporal-local-fork/bridge)
#     [--run-dir PATH]                 (default: mktemp OUTSIDE --repo)
#     [--max-seconds N]                (default 900; genuinely enforced -- this script owns the poll loop)
#     [--max-cost-cents N]             (default 200; POST-HOC WARNING ONLY -- a model call already in
#                                        flight cannot be preempted without touching the bridge's own
#                                        activity code, which is out of scope; see SKILL.md)
#     [--i-accept-headless-autonomous-risk]   (required if HERDR_ENV=1; see the HERDR_ENV guard below)
#   run-round-temporal.sh --selfcheck
#
# Env: SM_TEMPORAL_DRYRUN=1          -- print the assembled plan JSON + the commands this would run,
#                                        skip the real server/worker/build entirely (mirrors
#                                        launch-checker.sh's own SM_CHECKER_DRYRUN convention)
#      SM_TEMPORAL_GO_BIN            -- override the pinned Go toolchain (default matches the bridge's
#                                        own scripts/smoke_maker_checker.sh default)
#      SM_TEMPORAL_GO_DOWNLOAD_CACHE -- override the offline Go module cache (same default source)
#      SM_TEMPORAL_FETCH_TIMEOUT_SECONDS -- per-call ceiling (default 30) for a SINGLE `bridge fetch`
#                                        invocation; a call that exceeds it is treated as a failure
#                                        (exit 11), same as a genuine non-zero exit from the bridge
#                                        binary itself -- distinct from --max-seconds, the ceiling on
#                                        the WHOLE round across every fetch call
#
# NOTE: an earlier revision also read SM_TEMPORAL_FAKE_BRIDGE_BIN here to substitute a fake `bridge`
# binary for --selfcheck's own happy-path test. That was a real backdoor: cmd_round (the production
# round-running function) read it unconditionally from the ambient environment, so a stale export in
# a dispatcher's shell could silently replace a real round with forged output -- exactly the
# "fabricate success" failure mode this whole task must never allow. Removed entirely. The
# happy-path test now injects its fake bridge binary via an internal, non-exported, undocumented
# local variable that only --selfcheck's own direct in-process call to cmd_round can set (bash's
# dynamic scoping, not an environment read) -- structurally unreachable from any `round` subcommand
# invocation's inherited environment, no matter what an external caller exports. See cmd_round's own
# source for the mechanism; it is deliberately not part of this script's public interface.
#
# On success: stdout is EXACTLY the checker step's Output text (already secondmate's own
# verdict-envelope shape) -- pipe it straight into bin/verdict.py, zero translation. Everything else
# (heartbeats, cost/duration summary, bridge HEAD sha) goes to stderr.
#
# Exit codes: 0 ok | 1 preflight/environment failure | 2 usage error |
#             10 ZERO_COMMIT_ROUND (maker reported ok but left the worktree unchanged -- refused,
#                never handed to the checker) | 11 TEMPORAL_FETCH_FAILED (a `bridge fetch` call itself
#                exited non-zero -- a real engine/Temporal error, distinct from "not done yet") |
#                124 TEMPORAL_TIMEOUT (--max-seconds exceeded)
#
# NAMED LIMITATIONS (accepted, documented -- see skills/secondmate/SKILL.md for the full list):
# - Under HERDR_ENV=1, this script REFUSES a real round by default (see the guard in cmd_round):
#   the bridge's checker activity has no herdr-observable lifecycle at all (a bare headless `pi`
#   subprocess, not a live interruptible session), and its maker activity auto-accepts Bash
#   commands with zero intervention opportunity -- more autonomous than this repo's own normal
#   `--permission-mode auto` maker path, not merely less visible. Running THIS WRAPPER inside a
#   herdr pane does not fix either gap -- it only makes the wrapper's own output visible. Overridable
#   with --i-accept-headless-autonomous-risk, which also prints a loud warning before proceeding.
#   A separate task (task-id bridge-herdr-visible-activities) is already targeting the bridge itself
#   to make its maker/checker activities herdr-visible -- this guard's limitation is pending that
#   separate work landing, not indefinite.
# - No round-state.md/feature-list.json/ponytail/lesson-injection parity on this path (v1 scope).
# - No --lens support (the bridge's checker.go has no lens concept).
# - Process cleanup uses a PID+start-time fingerprint sidecar (see _fingerprint below); a `kill -9` on
#   THIS script itself defeats its own EXIT trap by definition -- a residual gap, not a bug.
# - Port allocation binds to port 0 and scrapes the OS-assigned port, same as the bridge's own
#   scripts/smoke*.sh; the gap between that scrape and the real server binding the same port number is
#   narrowed, not eliminated outright -- the prebuilt server binary takes a port NUMBER via CLI flag
#   only, with no socket-fd-passing/activation support to close this for real without touching the
#   read-only bridge binary.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_BRIDGE_DIR="/Users/eshwar.vijay/coupa/temporal-local-fork/bridge"
DEFAULT_GO_BIN="/Users/eshwar.vijay/coupa/temporal-pilot/.toolchain/go/bin/go"
DEFAULT_GO_DOWNLOAD_CACHE="/Users/eshwar.vijay/.herdr/worktrees/temporal-pilot/sm-temporal-hybrid-e2e-20261015/.toolchain/go-mod/cache/download"

# Per-call ceiling for a SINGLE `bridge fetch` invocation (distinct from --max-seconds, which only
# ever gets a chance to run BETWEEN completed fetch calls -- a single hung fetch would otherwise
# never hit that ceiling at all). Wrapped via run-round.sh, the same wall-clock+idle watchdog this
# repo already built for exactly this "macOS ships no timeout(1)" problem -- not a new technique.
FETCH_CALL_TIMEOUT_SECONDS="${SM_TEMPORAL_FETCH_TIMEOUT_SECONDS:-30}"
# Validated the instant it's read, before anything uses it -- same class of bug as a non-numeric
# --max-seconds/--max-cost-cents: a bad value would silently defeat this watchdog (the comparison
# inside run-round.sh's own `-ge` check fails, set -e doesn't propagate out of an if-condition).
case "$FETCH_CALL_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) echo "invalid SM_TEMPORAL_FETCH_TIMEOUT_SECONDS: $FETCH_CALL_TIMEOUT_SECONDS (want a non-negative integer)" >&2; exit 2;;
esac

# --- process-identity fingerprint sidecar (PID + start-time, not bare PID) ------------------------
# Same idiom as caffeinate-guard.sh's own _build_fingerprint: "comm=... lstart=..." lets a later
# invocation tell a reused PID apart from the real process before reaping it.
_fingerprint() {
  local pid="$1" comm lstart
  comm="$(ps -p "$pid" -o comm= 2>/dev/null)" || { echo ""; return; }
  lstart="$(ps -p "$pid" -o lstart= 2>/dev/null)" || { echo ""; return; }
  lstart="$(echo "$lstart" | sed 's/[[:space:]]*$//')"
  echo "comm=$comm lstart=$lstart"
}
_record_sidecar() {  # _record_sidecar <file> <pid>
  printf 'pid=%s\n%s\n' "$2" "$(_fingerprint "$2")" > "$1"
}
_kill_sidecar() {  # _kill_sidecar <file> -- no-op if missing, or if the fingerprint no longer matches
  local file="$1" pid fp_expected fp_actual
  [ -f "$file" ] || return 0
  pid="$(sed -n '1s/^pid=//p' "$file")"
  fp_expected="$(sed -n '2p' "$file")"
  [ -n "$pid" ] || return 0
  fp_actual="$(_fingerprint "$pid")"
  if [ -n "$fp_actual" ] && [ "$fp_actual" = "$fp_expected" ]; then
    kill "$pid" 2>/dev/null || true
  fi
}

# --- the one place a `bridge fetch` call actually happens: real exit code, real per-call ceiling ---
# Wraps the invocation in run-round.sh (this repo's own wall-clock+idle watchdog, reused rather than
# reimplemented) so a single HUNG fetch can't defeat --max-seconds either -- --max-seconds only ever
# gets a chance to run BETWEEN completed fetch calls, never during one still in flight. Writes the
# real stdout+stderr to <out_file> on success (same shape callers always expected); on ANY failure
# (a genuine non-zero exit from `bridge fetch` itself, or this call's own timeout/idle ceiling),
# returns 11 with a TEMPORAL_FETCH_FAILED message naming the real cause -- never silently retried.
_fetch_evidence() {  # _fetch_evidence <bridge_bin> <grpc_port> <wid> <rid> <out_file>
  local bridge_bin="$1" grpc_port="$2" wid="$3" rid="$4" out_file="$5" rc=0
  TEMPORAL_ADDRESS="127.0.0.1:$grpc_port" "$SCRIPT_DIR/run-round.sh" \
    --label bridge-fetch --log "$out_file" --audit "$(dirname "$out_file")/fetch-audit.jsonl" \
    --timeout "$FETCH_CALL_TIMEOUT_SECONDS" --idle "$FETCH_CALL_TIMEOUT_SECONDS" \
    -- "$bridge_bin" fetch --workflow-id "$wid" --run-id "$rid" || rc=$?
  case "$rc" in
    0) return 0 ;;
    124|125)
      echo "TEMPORAL_FETCH_FAILED: bridge fetch did not complete within ${FETCH_CALL_TIMEOUT_SECONDS}s (run-round.sh exit $rc) -- $(cat "$out_file" 2>/dev/null)" >&2
      return 11
      ;;
    *)
      echo "TEMPORAL_FETCH_FAILED: bridge fetch exited $rc -- $(cat "$out_file" 2>/dev/null)" >&2
      return 11
      ;;
  esac
}

# --- the one place a round's real changes are staged + committed: explicit paths, never -A/-u -----
# Reads `git status --porcelain -z` (NUL-delimited: no quoting ambiguity). A rename/copy carries a
# second NUL-terminated orig-path field; both the current path AND that orig path are added
# explicitly (never skipped) -- `git add` on a tracked path that's now missing from the worktree
# correctly stages its removal, which is what actually leaves the tree clean after the commit. The
# code check matches R/C in EITHER porcelain position (`R*|C*|*R|*C`), not just leading: a bare
# `mv old new; git add -N -- new` produces a leading-space code (" R", R in the SECOND position).
# Returns 10 (ZERO_COMMIT_ROUND) if the maker left nothing changed; otherwise stages + commits with
# the Temporal-Workflow-Id/Temporal-Run-Id trailers and prints the new HEAD sha.
_commit_round_changes() {  # _commit_round_changes <repo> <round> <goal> <wid> <rid>
  local repo="$1" round="$2" goal="$3" wid="$4" rid="$5"
  local paths=() pending_orig=0 entry code path
  while IFS= read -r -d '' entry; do
    if [ "$pending_orig" = 1 ]; then
      pending_orig=0
      # the orig/old path for a rename/copy: must be explicitly added too, never just skipped --
      # `git add` on a path that's tracked but now missing from the worktree correctly stages its
      # removal (confirmed live), which is what makes the commit leave a clean tree afterward.
      paths+=("$entry")
      continue
    fi
    code="${entry:0:2}"; path="${entry:3}"
    paths+=("$path")
    case "$code" in R*|C*|*R|*C) pending_orig=1;; esac
  done < <(git -C "$repo" status --porcelain -z)
  if [ "${#paths[@]}" -eq 0 ]; then
    return 10
  fi
  git -C "$repo" add -- "${paths[@]}"
  git -C "$repo" commit -q -m "Temporal round $round: $goal

Temporal-Workflow-Id: $wid
Temporal-Run-Id: $rid"
  git -C "$repo" rev-parse HEAD
}

_build_plan_json() {  # _build_plan_json <round> <goal> <criteria> <maker_prompt> <checker_goal>
  python3 -c '
import json, sys
round_n, goal, criteria, maker_prompt, checker_goal = sys.argv[1:6]
plan = {
    "schema_version": 1,
    "round": int(round_n),
    "goal": goal,
    "steps": [
        {"id": "step-maker", "kind": "maker", "params": {"workdir": ".", "prompt": maker_prompt}},
        {"id": "step-checker", "kind": "checker",
         "params": {"review_step": "step-maker", "workdir": ".", "goal": checker_goal}},
    ],
}
if criteria:
    plan["criteria"] = criteria
print(json.dumps(plan, indent=2))
' "$1" "$2" "$3" "$4" "$5"
}

usage() {
  echo "usage: $0 round --repo PATH --checker-goal TEXT (--maker-prompt-file F | --maker-prompt TEXT) [options]" >&2
  echo "       $0 --selfcheck" >&2
}

run_dir=""  # intentionally NOT local anywhere -- the EXIT/INT/TERM trap's cleanup() reads this global
run_dir_preexisted=0  # 1 iff --run-dir already existed on disk (as itself or via a symlink) BEFORE
                      # this invocation touched it. cleanup() must NEVER recursively delete anything
                      # this invocation did not itself create -- regardless of whether it's a symlink
                      # or a real directory, and regardless of whether it resolves under --bridge-dir
                      # or anywhere else. Confirmed live: a --run-dir symlink pointing at a
                      # pre-existing directory (itself containing a real file) got recursively
                      # deleted by a blind `rm -rf` on refusal -- exactly the kind of destruction this
                      # whole task must never do to the read-only bridge dependency, or to anything.

cleanup() {
  local ec=$?  # must be the FIRST command: preserves the real exit status through this whole handler,
               # regardless of what cleanup itself returns (a failing command below must never clobber it)
  _kill_sidecar "${run_dir}/worker.pidinfo"
  _kill_sidecar "${run_dir}/server.pidinfo"
  if [ -n "$run_dir" ] && [ "$run_dir_preexisted" != 1 ]; then
    # Go's module cache deliberately writes cached module directories read-only to prevent corruption;
    # a plain `rm -rf` on it fails with "Permission denied" (confirmed live) unless writable first.
    chmod -R u+w "$run_dir" 2>/dev/null || true
    rm -rf "$run_dir" 2>/dev/null || true
  fi
  exit "$ec"
}

cmd_round() {
  local repo="" round=1 goal="" criteria="" maker_prompt_file="" maker_prompt="" checker_goal="" prior_verdict_file=""
  local bridge_dir="$DEFAULT_BRIDGE_DIR" max_seconds=900 max_cost_cents=200 accept_headless_risk=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --i-accept-headless-autonomous-risk) accept_headless_risk=1; shift 1;;
      --repo) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; repo="$2"; shift 2;;
      --round) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; round="$2"; shift 2;;
      --goal) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; goal="$2"; shift 2;;
      --criteria) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; criteria="$2"; shift 2;;
      --maker-prompt-file) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; maker_prompt_file="$2"; shift 2;;
      --maker-prompt) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; maker_prompt="$2"; shift 2;;
      --checker-goal) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; checker_goal="$2"; shift 2;;
      --prior-verdict-file) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; prior_verdict_file="$2"; shift 2;;
      --bridge-dir) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; bridge_dir="$2"; shift 2;;
      --run-dir) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; run_dir="$2"; shift 2;;
      --max-seconds) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; max_seconds="$2"; shift 2;;
      --max-cost-cents) [ $# -ge 2 ] || { echo "$1 requires a value" >&2; return 2; }; max_cost_cents="$2"; shift 2;;
      *) echo "unknown arg: $1" >&2; return 2;;
    esac
  done

  [ -n "$repo" ] || { echo "need --repo PATH" >&2; usage; return 2; }
  [ -n "$checker_goal" ] || { echo "need --checker-goal TEXT" >&2; usage; return 2; }
  # [ -f ... ] is a bash builtin stat(), not a subprocess -- safe to check here, before the HERDR
  # guard below. Reading the FILE'S CONTENT (a real `cat` subprocess) is deferred to after the guard.
  if [ -n "$maker_prompt_file" ]; then
    [ -f "$maker_prompt_file" ] || { echo "maker-prompt-file not found: $maker_prompt_file" >&2; return 2; }
  fi
  [ -n "$maker_prompt_file" ] || [ -n "$maker_prompt" ] || { echo "need --maker-prompt-file F or --maker-prompt TEXT" >&2; usage; return 2; }
  [ -n "$goal" ] || goal="$checker_goal"
  case "$round" in ''|*[!0-9]*) echo "invalid --round: $round (want a non-negative integer)" >&2; return 2;; esac
  case "$max_seconds" in ''|*[!0-9]*) echo "invalid --max-seconds: $max_seconds (want a non-negative integer)" >&2; return 2;; esac
  case "$max_cost_cents" in ''|*[!0-9]*) echo "invalid --max-cost-cents: $max_cost_cents (want a non-negative integer)" >&2; return 2;; esac

  # --- HERDR_ENV=1 guard: refuse outright unless explicitly overridden --------------------------
  # This repo's own SOP (skills/secondmate/SKILL.md, "Visible orchestration in herdr") requires the
  # maker to run on a visible, interruptible herdr pane under HERDR_ENV=1, and explicitly PROHIBITS
  # headless checker execution there -- specifically so a human can observe and intervene on live,
  # autonomous model actions. The bridge's maker/checker activities (internal/planrun/maker.go,
  # checker.go -- read-only dependency, never modified by this script) cannot satisfy that, for TWO
  # distinct reasons, not one:
  #   (1) the checker runs as a bare headless `pi` subprocess with no herdr-tracked agent lifecycle
  #       at all -- a human watching a pane sees only this wrapper's own heartbeats and the final
  #       result, never a live, interruptible model session. Running this wrapper itself inside a
  #       herdr pane does NOT fix this -- it only makes the WRAPPER's output visible, not the inner
  #       checker process's state.
  #   (2) the maker runs `claude -p ... --permission-mode acceptEdits --allowedTools
  #       Read,Edit,Write,Bash` -- Bash commands are auto-accepted with ZERO intervention
  #       opportunity, which is MORE autonomous than this repo's own normal `--permission-mode auto`
  #       Claude maker path (which still blocks, visibly, on Bash/risky commands), not merely less
  #       visible.
  # Placed HERE -- immediately after arg validation, BEFORE _build_plan_json (a python3 subprocess)
  # or the git-worktree check or anything else that shells out -- so a refusal under HERDR_ENV=1
  # genuinely means nothing executed yet, not even a benign dry-run preview build. This is stricter
  # than an earlier revision, which placed the guard after _build_plan_json/the dry-run branch and
  # so still let a python3 subprocess run before refusing; the checker caught that.
  if [ "${HERDR_ENV:-}" = 1 ] && [ "$accept_headless_risk" != 1 ]; then
    echo "REFUSING: HERDR_ENV=1 and --i-accept-headless-autonomous-risk was not given. This engine's checker has no herdr-observable lifecycle at all (a bare headless subprocess, not a live interruptible session), and its maker auto-accepts Bash commands with zero intervention opportunity -- more autonomous than this repo's own normal maker path, not merely less visible. This repo's own SOP requires a visible, interruptible pane and prohibits headless checker execution under HERDR_ENV=1 for exactly this reason. Pass --i-accept-headless-autonomous-risk if you genuinely intend to run this engine under HERDR_ENV=1 anyway." >&2
    return 1
  fi
  if [ "${HERDR_ENV:-}" = 1 ]; then
    echo "WARNING: running under HERDR_ENV=1 with --i-accept-headless-autonomous-risk. This round's checker has NO herdr-observable lifecycle (a bare headless subprocess) and this round's maker auto-accepts Bash commands with zero intervention opportunity -- more autonomous than this repo's own normal maker path. Proceeding only because the override was explicitly given." >&2
  fi

  # Deferred from arg validation above: reading the FILE'S CONTENT is a real `cat` subprocess, so it
  # must happen only after the HERDR guard, same as everything else that shells out. (Confirmed live:
  # the checker's repro used a PATH-controlled `cat` to prove this ran before the guard refused, even
  # though the plain --maker-prompt TEXT path was already correctly ordered.)
  if [ -n "$maker_prompt_file" ]; then
    maker_prompt="$(cat "$maker_prompt_file")"
  fi

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "--repo $repo is not a git worktree" >&2; return 2; }
  repo="$(cd "$repo" && pwd)"

  local go_bin="${SM_TEMPORAL_GO_BIN:-$DEFAULT_GO_BIN}"
  local go_cache="${SM_TEMPORAL_GO_DOWNLOAD_CACHE:-$DEFAULT_GO_DOWNLOAD_CACHE}"
  # TESTING ONLY, not a caller-facing feature, and DELIBERATELY NOT an environment-variable read:
  # when set, substitutes a pre-built fake `bridge` binary for the real Go-built one, and skips the
  # real server-binary/Go-toolchain/claude/pi preflight checks and the real Temporal dev server --
  # lets --selfcheck drive a full happy-path cmd_round invocation with no real network/Temporal
  # server. `_sm_internal_test_fake_bridge_bin` is a PLAIN shell variable this script never exports
  # and never documents -- it is populated only via bash's dynamic scoping, by `_selfcheck`'s own
  # `local` declaration immediately before it calls `cmd_round` directly (not via a subprocess), and
  # is unconditionally absent/empty on the real `round` subcommand's own call path (a fresh process,
  # which inherits only the OS environment, never a caller's plain shell variables) -- so no value an
  # external caller could ever set in their ambient environment can reach this. An earlier revision
  # read this from SM_TEMPORAL_FAKE_BRIDGE_BIN (a real, exported env var) unconditionally inside this
  # same production function -- a genuine backdoor the checker confirmed live: a stale export in a
  # dispatcher's shell would silently replace a real round with a forged "successful" verdict.
  local fake_bridge_bin="${_sm_internal_test_fake_bridge_bin:-}"

  local checker_goal_full="$checker_goal"
  if [ -n "$prior_verdict_file" ]; then
    [ -f "$prior_verdict_file" ] || { echo "prior-verdict-file not found: $prior_verdict_file" >&2; return 2; }
    checker_goal_full="$checker_goal"$'\n\n'"Prior round verdict (resolve or re-confirm; don't re-litigate settled items):"$'\n'"$(cat "$prior_verdict_file")"
  fi

  local plan_json
  plan_json="$(_build_plan_json "$round" "$goal" "$criteria" "$maker_prompt" "$checker_goal_full")"

  if [ "${SM_TEMPORAL_DRYRUN:-}" = 1 ]; then
    echo "PLAN:"
    echo "$plan_json"
    echo "WOULD RUN: (cd $bridge_dir && GOWORK=off $go_bin build -o <run-dir>/bridge ./cmd/bridge)"
    echo "WOULD RUN: <run-dir>/bridge worker --pid-file <run-dir>/worker.pid   (BRIDGE_ROOT=$repo)"
    echo "WOULD RUN: <run-dir>/bridge submit --plan-file <run-dir>/plan.json --wait 0"
    echo "WOULD RUN: <run-dir>/bridge fetch --workflow-id <wid> --run-id <rid>   (polled every 5s up to ${max_seconds}s)"
    return 0
  fi

  # snapshot precondition for the real round: must be clean BEFORE we start, so the post-round diff
  # against this same snapshot is what decides ZERO_COMMIT_ROUND vs. a real change (dry-run never
  # starts anything real, so it is exempt from this check).
  [ -z "$(git -C "$repo" status --porcelain)" ] || { echo "refusing to start: $repo is not clean (uncommitted changes present)" >&2; return 1; }

  # --- preflight: refuse loudly, never silently degrade -------------------------------------------
  [ -d "$bridge_dir" ] || { echo "bridge dir not found: $bridge_dir (read-only dependency; override with --bridge-dir)" >&2; return 1; }
  # pwd -P (not plain pwd): resolves through symlinks to the REAL physical path, same idiom already
  # used elsewhere in this repo (mark-maker.sh, new-worktree.sh, merge-sequencer.sh,
  # sync-worktree-skills.sh) for exactly this class of containment check. A LEXICAL/plain-pwd
  # comparison is bypassable: a --run-dir that is, or resolves through, a symlink whose real target
  # physically sits under --bridge-dir would never match a string-prefix check on the unresolved path.
  bridge_dir="$(cd "$bridge_dir" && pwd -P)"

  # Record BEFORE this invocation touches anything: did --run-dir already exist on disk (as itself
  # or via a symlink -- `-e` follows symlinks)? If so, this invocation did NOT create it, and must
  # never recursively delete it later, no matter what else happens (refusal or normal cleanup).
  [ -n "$run_dir" ] && [ -e "$run_dir" ] && run_dir_preexisted=1
  run_dir="${run_dir:-$(mktemp -d "${TMPDIR:-/tmp}/sm-temporal-run.XXXXXX")}"
  mkdir -p "$run_dir"
  run_dir="$(cd "$run_dir" && pwd -P)"
  # Trap installed the INSTANT run_dir exists on disk, covering its entire lifetime -- every
  # preflight check below this line can fail and return 1, and each one must not leak run_dir.
  # cleanup() already tolerates firing this early: no sidecar files exist yet (_kill_sidecar no-ops
  # on a missing file), and cleanup() itself now respects run_dir_preexisted, so it never touches
  # anything that existed before this invocation started -- not the empty dir it may have just
  # created under bridge_dir, and never anything that was already there.
  trap cleanup EXIT INT TERM
  # never write a throwaway build/cache/temporal.db underneath the read-only bridge dependency's own tree
  case "$run_dir" in
    "$bridge_dir"|"$bridge_dir"/*)
      echo "refusing: --run-dir ($run_dir) is the same as or nested under --bridge-dir ($bridge_dir) -- must never write into the bridge prototype's own directory" >&2
      if [ "$run_dir_preexisted" != 1 ]; then
        rm -rf "$run_dir" 2>/dev/null || true  # this invocation's own freshly-created (empty) dir -- safe to remove ourselves, before the trap fires
      else
        echo "NOTE: --run-dir already existed before this invocation (as itself or via a symlink) -- left completely untouched, not removed, to avoid destroying pre-existing content." >&2
      fi
      run_dir=""
      return 1
      ;;
  esac

  local fork_root server_bin
  if [ -z "$fake_bridge_bin" ]; then
    fork_root="$(cd "$bridge_dir/.." && pwd)"
    server_bin="$fork_root/bin/temporal-local-standalone"
    [ -x "$server_bin" ] || { echo "prebuilt dev-server binary missing/not executable: $server_bin" >&2; return 1; }
    [ -x "$go_bin" ] || { echo "Go toolchain not found/not executable: $go_bin (override with SM_TEMPORAL_GO_BIN)" >&2; return 1; }
    [ -d "$go_cache" ] || { echo "Go module download cache not found: $go_cache (override with SM_TEMPORAL_GO_DOWNLOAD_CACHE)" >&2; return 1; }
    command -v claude >/dev/null 2>&1 || { echo "'claude' not on PATH (needed by the bridge's maker activity)" >&2; return 1; }
    command -v pi >/dev/null 2>&1 || { echo "'pi' not on PATH (needed by the bridge's checker activity)" >&2; return 1; }
  fi

  echo "$plan_json" > "$run_dir/plan.json"

  if [ -n "$fake_bridge_bin" ]; then
    echo "internal test-only fake bridge binary set -- skipping the real Go build (testing only)" >&2
    cp "$fake_bridge_bin" "$run_dir/bridge"
    chmod +x "$run_dir/bridge"
  else
    echo "building bridge CLI into $run_dir ..." >&2
    (
      cd "$bridge_dir"
      export GOTOOLCHAIN=local GOPROXY="file://$go_cache" GOSUMDB=off GOFLAGS=-mod=mod
      export GOMODCACHE="$run_dir/gomodcache" GOCACHE="$run_dir/gocache"
      mkdir -p "$GOMODCACHE" "$GOCACHE"
      GOWORK=off "$go_bin" build -o "$run_dir/bridge" ./cmd/bridge
    )
  fi

  # port 0 bind-and-scrape for both listeners, immediately followed by the real server launch using
  # the scraped port numbers -- see the module header's port-allocation limitation note.
  local grpc_port ui_port i
  if [ -n "$fake_bridge_bin" ]; then
    grpc_port=0  # unused by the fake bridge; no real server is started
    ui_port=0
  else
    grpc_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
    ui_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"

    echo "starting temporal dev server on 127.0.0.1:$grpc_port (ui $ui_port) ..." >&2
    "$server_bin" server start-dev --ip 127.0.0.1 --port "$grpc_port" --ui-ip 127.0.0.1 --ui-port "$ui_port" \
      --db-filename "$run_dir/temporal.db" --log-level error >"$run_dir/server.log" 2>&1 &
    _record_sidecar "$run_dir/server.pidinfo" "$!"

    for i in $(seq 1 100); do
      python3 -c 'import socket, sys
socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1).close()' "$grpc_port" 2>/dev/null && break
      sleep 0.3
    done
  fi

  echo "starting bridge worker (BRIDGE_ROOT=$repo) ..." >&2
  BRIDGE_ROOT="$repo" CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
  BRIDGE_CHECKER_PROMPT="$SCRIPT_DIR/checker-prompt.md" BRIDGE_CHECKER_ENVELOPE="$SCRIPT_DIR/checker-envelope.md" \
  BRIDGE_GO_BIN="$go_bin" TEMPORAL_ADDRESS="127.0.0.1:$grpc_port" \
    "$run_dir/bridge" worker --pid-file "$run_dir/worker.pid" >"$run_dir/worker.log" 2>&1 &
  for i in $(seq 1 50); do
    [ -f "$run_dir/worker.pid" ] && break
    sleep 0.2
  done
  [ -f "$run_dir/worker.pid" ] || { echo "worker failed to start (no pid file) -- see $run_dir/worker.log" >&2; return 1; }
  _record_sidecar "$run_dir/worker.pidinfo" "$(cat "$run_dir/worker.pid")"

  echo "submitting plan (round $round) ..." >&2
  local submit_out="$run_dir/submit.json" wid rid
  TEMPORAL_ADDRESS="127.0.0.1:$grpc_port" "$run_dir/bridge" submit --plan-file "$run_dir/plan.json" --wait 0 > "$submit_out"
  wid="$(python3 -c 'import json, sys
print(json.load(open(sys.argv[1]))["workflow_id"])' "$submit_out")"
  rid="$(python3 -c 'import json, sys
print(json.load(open(sys.argv[1]))["run_id"])' "$submit_out")"
  echo "workflow_id=$wid run_id=$rid" >&2

  # idle-watchdog-safe polling: --wait 0 above already returned; this script owns the poll loop and
  # prints one heartbeat per cycle so a wrapping run-round.sh's idle watchdog stays fed, while
  # genuinely exercising the query-vs-history bridge fetch path every round (not just a blocking --wait).
  local evidence_file="$run_dir/evidence.json" start_ts now elapsed done_flag
  start_ts=$(date +%s)
  while :; do
    _fetch_evidence "$run_dir/bridge" "$grpc_port" "$wid" "$rid" "$evidence_file" || return $?
    done_flag="$(python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print("1" if d.get("evidence", {}).get("done") else "0")
except Exception:
    print("0")' "$evidence_file")"
    now=$(date +%s); elapsed=$((now - start_ts))
    echo "heartbeat: elapsed=${elapsed}s max=${max_seconds}s done=${done_flag}" >&2
    [ "$done_flag" = "1" ] && break
    if [ "$elapsed" -ge "$max_seconds" ]; then
      echo "TEMPORAL_TIMEOUT: round did not complete within --max-seconds=$max_seconds" >&2
      return 124
    fi
    sleep 5
  done

  if [ -z "$(git -C "$repo" status --porcelain)" ]; then
    echo "ZERO_COMMIT_ROUND: maker step completed but left the worktree unchanged -- refusing to hand an empty diff to the checker" >&2
    return 10
  fi
  local commit_sha
  commit_sha="$(_commit_round_changes "$repo" "$round" "$goal" "$wid" "$rid")"
  echo "committed $commit_sha" >&2

  # re-fetch ONE more time from a brand-new, syntactically fresh `bridge fetch` process -- proves the
  # durable-read-from-a-new-process property, not just the poll loop's own repeated calls.
  local fresh_evidence="$run_dir/evidence.fresh.json"
  _fetch_evidence "$run_dir/bridge" "$grpc_port" "$wid" "$rid" "$fresh_evidence" || return $?

  python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
ev = d["evidence"]
checker = next(s for s in ev["steps"] if s["step_id"] == "step-checker")
print(checker.get("output", ""))' "$fresh_evidence"

  local bridge_head
  bridge_head="$(cd "$bridge_dir" && git rev-parse HEAD 2>/dev/null || echo unknown)"
  python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
ev = d["evidence"]
max_cost_cents = float(sys.argv[2])
total_cents = 0.0
for s in ev["steps"]:
    cost = s.get("cost_usd") or 0.0
    total_cents += cost * 100
    step_id = s["step_id"]
    status = s.get("status")
    duration_ms = s.get("duration_ms")
    print(f"{step_id}: status={status} duration_ms={duration_ms} cost_usd={cost}")
if total_cents > max_cost_cents:
    print(f"WARNING: total cost {total_cents:.1f} cents exceeds --max-cost-cents={max_cost_cents} (post-hoc warning only; could not be preempted mid-flight)")' "$fresh_evidence" "$max_cost_cents" >&2
  echo "bridge HEAD: $bridge_head" >&2
  echo "committed sha: $commit_sha (round $round)" >&2
}

_selfcheck() {
  local fails=0

  # --- arg validation ---
  local rc
  rc=0; "$0" round >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: no --repo exit $rc (want 2)"; fails=1; }
  rc=0; "$0" round --repo /tmp >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: no --checker-goal exit $rc (want 2)"; fails=1; }
  rc=0; "$0" round --repo /tmp --checker-goal x >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo "FAIL: no maker-prompt exit $rc (want 2)"; fails=1; }

  # --- fixture repo for the dry-run plan shape + the real preflight-refusal path ---
  local t; t="$(mktemp -d)"
  git -C "$t" init -q -b main; git -C "$t" config user.email a@a; git -C "$t" config user.name a
  echo seed > "$t/f"; git -C "$t" add -A; git -C "$t" commit -qm seed

  local out
  out="$(HERDR_ENV="" SM_TEMPORAL_DRYRUN=1 "$0" round --repo "$t" --checker-goal "check it" --maker-prompt "do it" --round 3 2>&1)" \
    || { echo "FAIL: dryrun errored"; fails=1; }
  echo "$out" | grep -q '"schema_version": 1' || { echo "FAIL: dryrun plan missing schema_version"; fails=1; }
  echo "$out" | grep -q '"round": 3'          || { echo "FAIL: dryrun plan missing round"; fails=1; }
  echo "$out" | grep -q '"kind": "maker"'     || { echo "FAIL: dryrun plan missing maker step"; fails=1; }
  echo "$out" | grep -q '"kind": "checker"'   || { echo "FAIL: dryrun plan missing checker step"; fails=1; }
  echo "$out" | grep -q '"review_step": "step-maker"' || { echo "FAIL: dryrun plan missing review_step wiring"; fails=1; }
  echo "$out" | grep -q '"workdir": "."'      || { echo "FAIL: dryrun plan missing workdir \".\""; fails=1; }

  # --round/--max-seconds/--max-cost-cents must be rejected at arg-parse time, BEFORE even the
  # dry-run path -- using a valid worktree + SM_TEMPORAL_DRYRUN=1 here (not /tmp) so the two
  # outcomes are genuinely distinguishable: validation present -> exit 2 from the new check;
  # validation missing -> exit 0 from the dry-run branch (never coincidentally the same exit code
  # either way). --round was previously unvalidated and only failed later with a raw Python
  # ValueError traceback from _build_plan_json's `int(round_n)` -- wrong exit code, implementation
  # leak instead of a controlled usage error.
  rc=0; SM_TEMPORAL_DRYRUN=1 "$0" round --repo "$t" --checker-goal x --maker-prompt y --round abc >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: non-numeric --round exit $rc (want 2)"; fails=1; }
  rc=0; SM_TEMPORAL_DRYRUN=1 "$0" round --repo "$t" --checker-goal x --maker-prompt y --max-seconds abc >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: non-numeric --max-seconds exit $rc (want 2)"; fails=1; }
  rc=0; SM_TEMPORAL_DRYRUN=1 "$0" round --repo "$t" --checker-goal x --maker-prompt y --max-cost-cents abc >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: non-numeric --max-cost-cents exit $rc (want 2)"; fails=1; }

  # --- SM_TEMPORAL_FETCH_TIMEOUT_SECONDS must be rejected the instant it's read (module scope),
  # same class of bug as --max-seconds/--max-cost-cents: a non-numeric value would silently defeat
  # the per-fetch-call watchdog. Uses a valid worktree + SM_TEMPORAL_DRYRUN=1 (not a bare `round`
  # with no args) so the two outcomes are genuinely distinguishable: validation present -> exit 2
  # from the module-level check, which fires before arg parsing even starts; validation missing ->
  # exit 0 from the dry-run branch (a bare `round` would coincidentally also exit 2 from the
  # separate missing-"--repo" check regardless of whether this validation ran at all -- same
  # coincidental-exit-code trap as an earlier round's own --max-seconds test, caught here before
  # relying on it). ---
  rc=0; HERDR_ENV="" SM_TEMPORAL_FETCH_TIMEOUT_SECONDS=abc SM_TEMPORAL_DRYRUN=1 "$0" round --repo "$t" --checker-goal x --maker-prompt y >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: non-numeric SM_TEMPORAL_FETCH_TIMEOUT_SECONDS exit $rc (want 2)"; fails=1; }

  # --- HERDR_ENV=1 guard: refuse a REAL round outright (before any build/server) unless the
  # override is explicitly given. Uses --bridge-dir /nonexistent so a subsequent bug couldn't
  # accidentally let this limp forward into real preflight/build work even if the guard failed to
  # fire -- the FIRST line of output must be the refusal, before any preflight message at all. ---
  rc=0
  out="$(HERDR_ENV=1 "$0" round --repo "$t" --checker-goal x --maker-prompt y --bridge-dir /nonexistent-xyz-$$ 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: HERDR_ENV=1 without override exit $rc (want 1)"; fails=1; }
  echo "$out" | grep -q 'REFUSING: HERDR_ENV=1' || { echo "FAIL: HERDR guard refusal message not found"; fails=1; }
  echo "$out" | grep -q 'no herdr-observable lifecycle' || { echo "FAIL: HERDR guard message missing the checker-visibility gap"; fails=1; }
  echo "$out" | grep -q 'auto-accepts Bash commands' || { echo "FAIL: HERDR guard message missing the maker-autonomy gap"; fails=1; }
  echo "$out" | grep -q 'bridge dir not found' && { echo "FAIL: HERDR guard did not fire first -- preflight ran instead"; fails=1; }

  # --- the HERDR guard must ALSO refuse before --maker-prompt-file's content is ever read (a real
  # `cat` subprocess) -- checker's exact repro: a PATH-controlled `cat` proved it ran before the
  # refusal fired, even though the plain --maker-prompt TEXT path was already correctly ordered.
  # Uses a fake `cat` on PATH that leaves a real marker file if it's ever invoked. ---
  local herdr_cat_fixture; herdr_cat_fixture="$(mktemp -d)"
  mkdir -p "$herdr_cat_fixture/bin"
  local herdr_cat_marker="$herdr_cat_fixture/cat-ran-marker"
  cat > "$herdr_cat_fixture/bin/cat" <<CAT_RAN_EOF
#!/usr/bin/env bash
touch "$herdr_cat_marker"
exec /bin/cat "\$@"
CAT_RAN_EOF
  chmod +x "$herdr_cat_fixture/bin/cat"
  local prompt_file="$herdr_cat_fixture/prompt.txt"
  echo "some prompt text" > "$prompt_file"
  rc=0
  out="$(PATH="$herdr_cat_fixture/bin:$PATH" HERDR_ENV=1 "$0" round --repo "$t" --checker-goal x \
    --maker-prompt-file "$prompt_file" --bridge-dir /nonexistent-xyz-$$ 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: HERDR guard with --maker-prompt-file exit $rc (want 1)"; fails=1; }
  echo "$out" | grep -q 'REFUSING: HERDR_ENV=1' || { echo "FAIL: HERDR guard refusal message not found for the --maker-prompt-file path"; fails=1; }
  [ ! -f "$herdr_cat_marker" ] || { echo "FAIL: --maker-prompt-file's cat subprocess ran BEFORE the HERDR guard refused"; fails=1; }
  rm -rf "$herdr_cat_fixture"

  # --- the override must actually let a real round proceed PAST the guard -- paired with
  # --bridge-dir /nonexistent so it still exits early for an unrelated reason, confirming only that
  # the HERDR guard itself did not block it (same precedent as the dry-run/missing-bridge-dir tests
  # elsewhere in this suite: a clean, fast, no-live-Temporal way to observe "did this check pass"). ---
  rc=0
  out="$(HERDR_ENV=1 "$0" round --repo "$t" --checker-goal x --maker-prompt y --bridge-dir /nonexistent-xyz-$$ --i-accept-headless-autonomous-risk 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: HERDR_ENV=1 WITH override exit $rc (want 1, from the unrelated missing-bridge-dir refusal)"; fails=1; }
  echo "$out" | grep -q 'REFUSING: HERDR_ENV=1' && { echo "FAIL: HERDR guard still blocked despite the override being given"; fails=1; }
  echo "$out" | grep -q 'WARNING: running under HERDR_ENV=1' || { echo "FAIL: HERDR guard override did not print the expected warning"; fails=1; }
  echo "$out" | grep -q 'bridge dir not found' || { echo "FAIL: override did not let the round proceed to the next real check"; fails=1; }

  # --- the HERDR guard must be positioned in the SOURCE before _build_plan_json is ever called, so
  # a refusal genuinely means nothing executed yet -- not even a benign plan-preview python3
  # subprocess. There is no black-box way to observe "did a python3 subprocess run" from outside, so
  # this pins the ordering invariant structurally against the script's own source instead. ---
  local guard_line build_call_line
  guard_line="$(grep -n 'REFUSING: HERDR_ENV=1 and --i-accept-headless-autonomous-risk' "$0" | head -1 | cut -d: -f1)"
  build_call_line="$(grep -n 'plan_json="\$(_build_plan_json' "$0" | head -1 | cut -d: -f1)"
  if [ -z "$guard_line" ] || [ -z "$build_call_line" ]; then
    echo "FAIL: could not locate guard/build-call lines for ordering check"; fails=1
  elif [ "$guard_line" -ge "$build_call_line" ]; then
    echo "FAIL: HERDR guard must appear BEFORE the _build_plan_json call in cmd_round (guard line $guard_line, build-call line $build_call_line)"; fails=1
  fi

  rc=0; HERDR_ENV="" "$0" round --repo "$t" --checker-goal x --maker-prompt y --bridge-dir /nonexistent-xyz-$$ >/tmp/sm-temporal-selfcheck-pf.$$ 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: missing-bridge-dir exit $rc (want 1)"; fails=1; }
  grep -q 'bridge dir not found' /tmp/sm-temporal-selfcheck-pf.$$ || { echo "FAIL: missing-bridge-dir message not found"; fails=1; }
  rm -f /tmp/sm-temporal-selfcheck-pf.$$

  # --- refuse when --run-dir is the same as or nested under --bridge-dir: never write a throwaway
  # build/cache/temporal.db underneath the read-only bridge dependency's own tree. Uses a fake
  # existing directory as the "bridge dir" -- the nested-run-dir check runs before the heavier
  # server-binary/Go-toolchain/claude/pi preflight checks, so this needs none of those to be present. ---
  local fake_bridge; fake_bridge="$(mktemp -d)"
  rc=0
  HERDR_ENV="" "$0" round --repo "$t" --checker-goal x --maker-prompt y \
    --bridge-dir "$fake_bridge" --run-dir "$fake_bridge/nested-run-dir" \
    >/tmp/sm-temporal-selfcheck-nest.$$ 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: nested --run-dir-under-bridge-dir exit $rc (want 1)"; fails=1; }
  grep -q 'nested under --bridge-dir' /tmp/sm-temporal-selfcheck-nest.$$ || { echo "FAIL: nested-run-dir message not found"; fails=1; }
  [ ! -e "$fake_bridge/nested-run-dir" ] || { echo "FAIL: refused run-dir was not cleaned up (still exists under bridge-dir)"; fails=1; }
  rm -f /tmp/sm-temporal-selfcheck-nest.$$

  # --- the SAME refusal must fire even when --run-dir is a symlink whose REAL target physically
  # sits under --bridge-dir: a lexical/string comparison on the unresolved paths would miss this
  # (confirmed: plain `pwd` after `cd` through a symlink prints the symlink path, not the real one;
  # `pwd -P` resolves it). The symlink's target is pre-created (not dangling) because `mkdir -p` on a
  # dangling symlink fails outright on this platform's mkdir (confirmed live) -- a pre-existing target
  # is also the more realistic shape of a real bypass attempt anyway. ---
  mkdir -p "$fake_bridge/real-target"
  local outside_link; outside_link="$(mktemp -d)"
  ln -s "$fake_bridge/real-target" "$outside_link/run-dir-link"
  rc=0
  HERDR_ENV="" "$0" round --repo "$t" --checker-goal x --maker-prompt y \
    --bridge-dir "$fake_bridge" --run-dir "$outside_link/run-dir-link" \
    >/tmp/sm-temporal-selfcheck-symlink.$$ 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: symlinked --run-dir resolving under --bridge-dir exit $rc (want 1)"; fails=1; }
  grep -q 'nested under --bridge-dir' /tmp/sm-temporal-selfcheck-symlink.$$ || { echo "FAIL: symlinked-run-dir message not found -- lexical check bypassed by the symlink"; fails=1; }
  rm -f /tmp/sm-temporal-selfcheck-symlink.$$
  rm -rf "$outside_link"
  rm -rf "$fake_bridge"

  # --- [CRITICAL] the containment refusal must NEVER recursively delete pre-existing content, even
  # when the resolved run_dir sits under bridge_dir. Checker's exact repro: --run-dir is a symlink
  # pointing at an EXISTING directory inside --bridge-dir that already contains a real "sentinel"
  # file. Before this fix, the refusal path did a blind `rm -rf` on the RESOLVED (symlink-followed)
  # path, destroying both the pre-existing directory and the file inside it -- exactly the kind of
  # destruction under the read-only bridge dependency this whole task must never do. ---
  local destr_bridge; destr_bridge="$(mktemp -d)"
  mkdir -p "$destr_bridge/existing-target"
  echo "sentinel-content-$$" > "$destr_bridge/existing-target/sentinel.txt"
  local destr_link; destr_link="$(mktemp -d)"
  ln -s "$destr_bridge/existing-target" "$destr_link/run-dir-link"
  rc=0
  HERDR_ENV="" "$0" round --repo "$t" --checker-goal x --maker-prompt y \
    --bridge-dir "$destr_bridge" --run-dir "$destr_link/run-dir-link" \
    >/tmp/sm-temporal-selfcheck-destructive.$$ 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: destructive-symlink-repro exit $rc (want 1)"; fails=1; }
  [ -d "$destr_bridge/existing-target" ] || { echo "FAIL [CRITICAL]: pre-existing target directory was deleted by the refusal path"; fails=1; }
  [ -f "$destr_bridge/existing-target/sentinel.txt" ] || { echo "FAIL [CRITICAL]: pre-existing sentinel file was deleted by the refusal path"; fails=1; }
  [ "$(cat "$destr_bridge/existing-target/sentinel.txt" 2>/dev/null)" = "sentinel-content-$$" ] || { echo "FAIL [CRITICAL]: sentinel content changed/corrupted"; fails=1; }
  rm -f /tmp/sm-temporal-selfcheck-destructive.$$
  rm -rf "$destr_link"
  rm -rf "$destr_bridge"

  # --- a preflight failure AFTER run_dir is created but that the OLD trap placement (set only after
  # ALL preflight checks) never covered must not leak run_dir on disk. Uses a fake bridge-dir+server
  # binary so the missing-Go-toolchain check is what actually fails, exercising exactly the gap
  # between run_dir creation and the old trap registration point. ---
  local leak_root; leak_root="$(mktemp -d)"
  mkdir -p "$leak_root/fakebridge/bridge" "$leak_root/fakebridge/bin"
  touch "$leak_root/fakebridge/bin/temporal-local-standalone"
  chmod +x "$leak_root/fakebridge/bin/temporal-local-standalone"
  local leak_run_dir="$leak_root/explicit-run-dir"
  rc=0
  HERDR_ENV="" SM_TEMPORAL_GO_BIN="/nonexistent-go-xyz-$$" "$0" round --repo "$t" --checker-goal x --maker-prompt y \
    --bridge-dir "$leak_root/fakebridge/bridge" --run-dir "$leak_run_dir" \
    >/tmp/sm-temporal-selfcheck-trap.$$ 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL: missing-go-bin exit $rc (want 1)"; fails=1; }
  grep -q 'Go toolchain not found' /tmp/sm-temporal-selfcheck-trap.$$ || { echo "FAIL: missing-go-bin message not found"; fails=1; }
  [ ! -e "$leak_run_dir" ] || { echo "FAIL: run_dir leaked after a preflight failure past run_dir creation (trap not covering this span)"; fails=1; }
  rm -f /tmp/sm-temporal-selfcheck-trap.$$
  rm -rf "$leak_root"

  # --- _fetch_evidence must surface a real `bridge fetch` failure as exit 11/TEMPORAL_FETCH_FAILED,
  # not loop/time out -- exercised directly against a fake "bridge" stub (fast, free, no live
  # Temporal), the same PATH/stub-faking idiom bin/teardown-check.sh already uses for an external CLI. ---
  local fe_dir; fe_dir="$(mktemp -d)"
  cat > "$fe_dir/fake-bridge" <<'FAKE_BRIDGE_EOF'
#!/usr/bin/env bash
case "$1" in
  fetch) echo "simulated bridge fetch failure" >&2; exit 7 ;;
  *) exit 1 ;;
esac
FAKE_BRIDGE_EOF
  chmod +x "$fe_dir/fake-bridge"
  rc=0
  fe_out="$(_fetch_evidence "$fe_dir/fake-bridge" 1 WID RID "$fe_dir/evidence.out" 2>&1)" || rc=$?
  [ "$rc" = 11 ] || { echo "FAIL: _fetch_evidence on a failing bridge exit $rc (want 11)"; fails=1; }
  echo "$fe_out" | grep -q 'TEMPORAL_FETCH_FAILED' || { echo "FAIL: TEMPORAL_FETCH_FAILED message not found for a failing bridge fetch"; fails=1; }

  # --- _fetch_evidence must ALSO treat a HUNG single fetch call as a failure (exit 11), not let it
  # defeat --max-seconds by never returning control to the poll loop's own elapsed-time check.
  # Overrides the per-call ceiling to 1s (via SM_TEMPORAL_FETCH_TIMEOUT_SECONDS) so this stays fast. ---
  cat > "$fe_dir/fake-bridge-hang" <<'FAKE_BRIDGE_HANG_EOF'
#!/usr/bin/env bash
case "$1" in
  fetch) sleep 30 ;;
  *) exit 1 ;;
esac
FAKE_BRIDGE_HANG_EOF
  chmod +x "$fe_dir/fake-bridge-hang"
  local orig_fetch_timeout="$FETCH_CALL_TIMEOUT_SECONDS"
  FETCH_CALL_TIMEOUT_SECONDS=1
  rc=0
  fe_out="$(POLL=1 _fetch_evidence "$fe_dir/fake-bridge-hang" 1 WID RID "$fe_dir/evidence-hang.out" 2>&1)" || rc=$?
  FETCH_CALL_TIMEOUT_SECONDS="$orig_fetch_timeout"
  [ "$rc" = 11 ] || { echo "FAIL: _fetch_evidence on a HUNG bridge exit $rc (want 11)"; fails=1; }
  echo "$fe_out" | grep -q 'TEMPORAL_FETCH_FAILED' || { echo "FAIL: TEMPORAL_FETCH_FAILED message not found for a hung bridge fetch"; fails=1; }
  rm -rf "$fe_dir"

  # --- Happy path: a full cmd_round invocation, driven end to end through a FAKE "bridge" CLI stub
  # (worker/submit/fetch implementing just enough of the real bridge's actual output shape to return
  # canned, fast, successful JSON) -- no real network/Temporal server. Closes the "Happy path: NO"
  # test-coverage gap the checker named. The fake worker writes a real marker file into BRIDGE_ROOT
  # (standing in for "the maker made a real change") the instant it starts, before the fake fetch
  # ever reports done=true, so the real git-status/_commit_round_changes logic runs for real against
  # a real diff. The fake bridge binary is injected via `_sm_internal_test_fake_bridge_bin`, a plain
  # (never-exported, never-documented) local variable set right below, visible to cmd_round ONLY
  # through bash's dynamic scoping across this direct function call -- deliberately NOT an
  # environment variable, so nothing an external caller could ever export reaches cmd_round's real
  # `round`-subcommand path (see cmd_round's own declaration of fake_bridge_bin for the full
  # rationale: an earlier revision's SM_TEMPORAL_FAKE_BRIDGE_BIN env var was a genuine backdoor). ---
  local hp_repo; hp_repo="$(mktemp -d)"
  git -C "$hp_repo" init -q -b main
  git -C "$hp_repo" config user.email a@a
  git -C "$hp_repo" config user.name a
  echo seed > "$hp_repo/f"
  git -C "$hp_repo" add -A
  git -C "$hp_repo" commit -qm seed

  local hp_fake_dir; hp_fake_dir="$(mktemp -d)"
  cat > "$hp_fake_dir/fake-bridge-happy" <<'FAKE_HAPPY_EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  worker)
    shift
    pidfile=""
    while [ $# -gt 0 ]; do case "$1" in --pid-file) pidfile="$2"; shift 2;; *) shift;; esac; done
    if [ -n "${BRIDGE_ROOT:-}" ]; then
      echo "fake maker change" > "$BRIDGE_ROOT/.sm-happy-path-marker"
    fi
    [ -n "$pidfile" ] && echo $$ > "$pidfile"
    while :; do sleep 1; done
    ;;
  submit)
    shift
    planfile=""
    while [ $# -gt 0 ]; do case "$1" in --plan-file) planfile="$2"; shift 2;; *) shift;; esac; done
    round="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["round"])' "$planfile")"
    printf '{"workflow_id":"WID-FAKE","run_id":"RID-FAKE","round":%s,"status":"started"}\n' "$round"
    ;;
  fetch)
    cat <<'JSON'
{"workflow_id":"WID-FAKE","run_id":"RID-FAKE","status":"COMPLETED","evidence_source":"history","evidence":{"schema_version":1,"round":1,"goal":"fake happy path","steps":[{"step_id":"step-maker","kind":"maker","status":"ok","output":"fake maker summary","duration_ms":5,"cost_usd":0.001,"diff":"fake diff"},{"step_id":"step-checker","kind":"checker","status":"ok","output":"FAKE_HAPPY_PATH_CHECKER_OUTPUT_SENTINEL","duration_ms":5,"cost_usd":0.001,"verdict":"pass"}],"done":true,"completed_at":"2026-01-01T00:00:00Z"}}
JSON
    ;;
  *) exit 1 ;;
esac
FAKE_HAPPY_EOF
  chmod +x "$hp_fake_dir/fake-bridge-happy"

  local hp_run_dir; hp_run_dir="$(mktemp -d)"
  rmdir "$hp_run_dir"  # cmd_round's own mkdir -p must be what creates it, so this proves nothing leaks
  local _sm_internal_test_fake_bridge_bin="$hp_fake_dir/fake-bridge-happy"
  local hp_out hp_rc=0
  hp_out="$(POLL=1 HERDR_ENV="" cmd_round \
    --repo "$hp_repo" --checker-goal "happy path check" --maker-prompt "happy path make" \
    --bridge-dir "$hp_fake_dir" --run-dir "$hp_run_dir" 2>/tmp/sm-temporal-selfcheck-happy-err.$$)" || hp_rc=$?
  if [ "$hp_rc" != 0 ]; then
    echo "FAIL: happy-path cmd_round exit $hp_rc (want 0); stderr:"; fails=1
    cat /tmp/sm-temporal-selfcheck-happy-err.$$
  fi
  [ "$hp_out" = "FAKE_HAPPY_PATH_CHECKER_OUTPUT_SENTINEL" ] || { echo "FAIL: happy-path stdout did not match the checker Output verbatim: $hp_out"; fails=1; }
  git -C "$hp_repo" log -1 --format=%B | grep -q 'Temporal-Workflow-Id: WID-FAKE' || { echo "FAIL: happy-path commit missing Temporal-Workflow-Id trailer"; fails=1; }
  git -C "$hp_repo" log -1 --format=%B | grep -q 'Temporal-Run-Id: RID-FAKE'      || { echo "FAIL: happy-path commit missing Temporal-Run-Id trailer"; fails=1; }
  [ -f "$hp_repo/.sm-happy-path-marker" ] || { echo "FAIL: happy-path fake maker marker file missing -- the real diff/commit path was never exercised"; fails=1; }
  [ -z "$(git -C "$hp_repo" status --porcelain)" ] || { echo "FAIL: happy-path repo not clean after commit"; fails=1; }
  [ ! -e "$hp_run_dir" ] || { echo "FAIL: happy-path run_dir was not cleaned up after a successful round"; fails=1; }
  rm -f /tmp/sm-temporal-selfcheck-happy-err.$$
  rm -rf "$hp_fake_dir" "$hp_repo"

  # --- [SECURITY, CRITICAL] setting the OLD env var name (SM_TEMPORAL_FAKE_BRIDGE_BIN) in the
  # ambient environment of a REAL `round` subprocess invocation must have ZERO effect -- this is the
  # exact backdoor the checker confirmed live (a stale export in a dispatcher's shell silently
  # replacing a real round with forged output). Uses a real subprocess invocation (not the direct
  # function call the happy-path test above uses), with an "evil" bridge binary that would prove it
  # ran (by writing a sentinel file into the target repo) and would forge a passing checker verdict
  # if the old env-var mechanism still worked -- against a bridge-dir fixture missing the real
  # server binary, so if the env var is correctly ignored, the REAL missing-server-binary preflight
  # check fires first, exactly as it would for any ordinary caller with a stale export. ---
  local evil_dir; evil_dir="$(mktemp -d)"
  cat > "$evil_dir/evil-bridge" <<'EVIL_BRIDGE_EOF'
#!/usr/bin/env bash
[ -n "${BRIDGE_ROOT:-}" ] && echo "EVIL_BRIDGE_RAN" > "$BRIDGE_ROOT/.evil-ran-marker"
case "$1" in
  worker) while :; do sleep 1; done ;;
  submit) echo '{"workflow_id":"EVIL","run_id":"EVIL","round":1,"status":"started"}' ;;
  fetch) echo '{"workflow_id":"EVIL","run_id":"EVIL","status":"COMPLETED","evidence_source":"history","evidence":{"schema_version":1,"round":1,"goal":"evil","steps":[{"step_id":"step-maker","kind":"maker","status":"ok","output":"evil maker","diff":"evil"},{"step_id":"step-checker","kind":"checker","status":"ok","output":"EVIL_FORGED_PASS_VERDICT","verdict":"pass"}],"done":true}}' ;;
esac
EVIL_BRIDGE_EOF
  chmod +x "$evil_dir/evil-bridge"
  local sec_bridge; sec_bridge="$(mktemp -d)"
  local sec_repo; sec_repo="$(mktemp -d)"
  git -C "$sec_repo" init -q -b main; git -C "$sec_repo" config user.email a@a; git -C "$sec_repo" config user.name a
  echo seed > "$sec_repo/f"; git -C "$sec_repo" add -A; git -C "$sec_repo" commit -qm seed
  rc=0
  out="$(SM_TEMPORAL_FAKE_BRIDGE_BIN="$evil_dir/evil-bridge" HERDR_ENV="" "$0" round \
    --repo "$sec_repo" --checker-goal x --maker-prompt y --bridge-dir "$sec_bridge" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "FAIL [SECURITY]: ambient SM_TEMPORAL_FAKE_BRIDGE_BIN export exit $rc (want 1, from the real missing-server-binary preflight check)"; fails=1; }
  echo "$out" | grep -q 'prebuilt dev-server binary missing' || { echo "FAIL [SECURITY]: ambient SM_TEMPORAL_FAKE_BRIDGE_BIN export did not hit the real preflight check -- output: $out"; fails=1; }
  [ ! -f "$sec_repo/.evil-ran-marker" ] || { echo "FAIL [SECURITY, CRITICAL]: the evil binary ACTUALLY RAN via an ambient env var -- backdoor still open"; fails=1; }
  echo "$out" | grep -q 'EVIL_FORGED_PASS_VERDICT' && { echo "FAIL [SECURITY, CRITICAL]: forged checker output reached stdout via an ambient env var"; fails=1; }
  rm -rf "$evil_dir" "$sec_bridge" "$sec_repo"

  # --- explicit-path git-add + zero-commit-round refusal, against the real function ---
  if _commit_round_changes "$t" 1 "g" "W" "R" >/dev/null 2>/tmp/sm-temporal-selfcheck-zc.$$; then
    echo "FAIL: _commit_round_changes on a clean repo should return 10 (ZERO_COMMIT_ROUND)"; fails=1
  else
    rc=$?; [ "$rc" = 10 ] || { echo "FAIL: clean-repo rc=$rc (want 10)"; fails=1; }
  fi
  rm -f /tmp/sm-temporal-selfcheck-zc.$$

  echo "changed" >> "$t/f"
  local sha
  sha="$(_commit_round_changes "$t" 2 "a real goal" "WID123" "RID456")" || { echo "FAIL: _commit_round_changes on a dirty repo should succeed"; fails=1; }
  [ -n "$sha" ] && [ "$(git -C "$t" rev-parse HEAD)" = "$sha" ] || { echo "FAIL: returned sha does not match new HEAD"; fails=1; }
  git -C "$t" show --stat -q "$sha" | grep -q ' f \b' || true  # advisory only, path formatting varies
  git -C "$t" log -1 --format=%B "$sha" | grep -q 'Temporal-Workflow-Id: WID123' || { echo "FAIL: commit missing Temporal-Workflow-Id trailer"; fails=1; }
  git -C "$t" log -1 --format=%B "$sha" | grep -q 'Temporal-Run-Id: RID456'      || { echo "FAIL: commit missing Temporal-Run-Id trailer"; fails=1; }
  [ -z "$(git -C "$t" status --porcelain)" ] || { echo "FAIL: repo not clean after commit"; fails=1; }
  rm -rf "$t"

  # --- rename/copy detection must catch R/C in EITHER porcelain position, not just leading: a bare
  # `mv old new; git add -N -- new` produces a leading-SPACE code (" R", R in the SECOND position --
  # confirmed live). The old `R*|C*` pattern missed this, wrongly appended the orig-path field as a
  # bogus extra "changed path", and `git add -- new ""` failed. ---
  local rt; rt="$(mktemp -d)"
  git -C "$rt" init -q -b main; git -C "$rt" config user.email a@a; git -C "$rt" config user.name a
  echo content > "$rt/old"; git -C "$rt" add -A; git -C "$rt" commit -qm seed
  mv "$rt/old" "$rt/new"
  git -C "$rt" add -N -- new
  local rename_sha
  rename_sha="$(_commit_round_changes "$rt" 3 "rename repro" "WIDREN" "RIDREN")" \
    || { echo "FAIL: _commit_round_changes must succeed on the \" R\" (space, R) rename repro"; fails=1; }
  if [ -n "${rename_sha:-}" ]; then
    [ "$(git -C "$rt" rev-parse HEAD)" = "$rename_sha" ] || { echo "FAIL: rename-repro returned sha does not match new HEAD"; fails=1; }
    git -C "$rt" show --stat -q "$rename_sha" | grep -q 'new' || { echo "FAIL: rename-repro commit does not mention the new path"; fails=1; }
    [ -z "$(git -C "$rt" status --porcelain)" ] || { echo "FAIL: rename-repro repo not clean after commit (bogus empty path staged?)"; fails=1; }
  fi
  rm -rf "$rt"

  # --- fingerprint-sidecar kill logic: real process killed; wrong fingerprint is never killed ---
  local sc="$(mktemp -d)"
  sleep 30 & local live_pid=$!
  _record_sidecar "$sc/ok.pidinfo" "$live_pid"
  _kill_sidecar "$sc/ok.pidinfo"
  sleep 0.3
  kill -0 "$live_pid" 2>/dev/null && { echo "FAIL: _kill_sidecar did not kill the matching-fingerprint process"; fails=1; kill -9 "$live_pid" 2>/dev/null || true; }

  sleep 30 & local live_pid2=$!
  printf 'pid=%s\ncomm=not-the-real-comm lstart=not-the-real-time\n' "$live_pid2" > "$sc/stale.pidinfo"
  _kill_sidecar "$sc/stale.pidinfo"
  sleep 0.3
  kill -0 "$live_pid2" 2>/dev/null || { echo "FAIL: _kill_sidecar killed a process whose fingerprint did not match"; fails=1; }
  kill -9 "$live_pid2" 2>/dev/null || true
  rm -rf "$sc"

  # --- cleanup() must preserve the real exit code even when its own rm/chmod fails (confirmed live:
  # Go's module cache ships read-only directories; an unguarded `rm -rf` on it failed and clobbered a
  # genuinely successful round's exit 0 into exit 1) ---
  local cd2; cd2="$(mktemp -d)"
  mkdir -p "$cd2/locked_parent/child_run_dir"
  echo x > "$cd2/locked_parent/child_run_dir/f"
  chmod 555 "$cd2/locked_parent"
  local crc=0
  # 42 is deliberately distinct from rm's own natural failure code (1), so a cleanup that lets the
  # failing rm's exit status leak through instead of preserving the real one is caught, not masked by
  # a coincidental match.
  ( run_dir="$cd2/locked_parent/child_run_dir"; ( exit 42 ); cleanup ) || crc=$?
  chmod 755 "$cd2/locked_parent" 2>/dev/null || true
  rm -rf "$cd2"
  [ "$crc" = 42 ] || { echo "FAIL: cleanup must preserve the pre-trap exit code even when its own rm fails (got $crc, want 42)"; fails=1; }

  [ "$fails" = 0 ] && echo ok
  return "$fails"
}

case "${1:-}" in
  --selfcheck) _selfcheck; exit $? ;;
  round) shift; cmd_round "$@"; exit $? ;;
  *) usage; exit 2 ;;
esac
