#!/usr/bin/env bash
# verify-gate.sh -- pre-integration gate for the maker/checker loop.
#   #3 state-reconciliation: don't trust the maker's "done" -- re-derive ground truth from the worktree.
#   #2 exact-SHA gate:       refuse if the head moved since the checker's verdict (stale approval).
# Run this BEFORE the supervisor integrates/merges a maker's branch. Fail-closed: reports EVERY failing
# condition and exits non-zero unless all pass (mirrors fm-pr-merge.sh reporting every blocker).
#
#   verify-gate.sh --worktree PATH --base REF [--checked-sha SHA] [--test "pytest -q"]
#   verify-gate.sh --selfcheck
set -euo pipefail

worktree="" base="main" checked_sha="" test_cmd="" selfcheck=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) worktree="$2"; shift 2;;
    --base) base="$2"; shift 2;;
    --checked-sha) checked_sha="$2"; shift 2;;
    --test) test_cmd="$2"; shift 2;;
    --selfcheck) selfcheck=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

gate() {  # gate <worktree> <base> <checked_sha> <test_cmd> ; prints PASS/REFUSE, returns 0 only if clean
  local wt="$1" base="$2" checked="$3" tcmd="$4"
  local -a fail=()
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "REFUSE: $wt is not a git worktree"; return 1
  fi
  # #3a: working tree must be clean (no uncommitted maker work)
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail+=("working tree is dirty (uncommitted changes)")
  # base must resolve
  local base_sha=""; base_sha="$(git -C "$wt" rev-parse --verify "${base}^{commit}" 2>/dev/null || true)"
  [ -n "$base_sha" ] || fail+=("base ref '$base' does not resolve")
  local head; head="$(git -C "$wt" rev-parse HEAD)"
  # #3b: maker actually produced changes vs base
  if [ -n "$base_sha" ] && git -C "$wt" diff --quiet "$base_sha".."$head"; then
    fail+=("no changes vs base (maker produced an empty diff)")
  fi
  # #2: exact-SHA gate -- checker verdict must match the head we're about to ship
  if [ -n "$checked" ] && [ "$checked" != "$head" ]; then
    fail+=("head moved since checker verdict: checked=$checked now=$head (RE-RUN THE CHECKER)")
  fi
  # #3c: re-run the test against the current head. --test is a TRUSTED, supervisor-supplied command by
  # design (it's "run this test"); run it via `bash -c`. THEN re-read HEAD: if the test moved it (e.g. it
  # committed), the exact-SHA approval is now stale -> refuse (finding #10).
  if [ -n "$tcmd" ]; then
    ( cd "$wt" && bash -c "$tcmd" ) >/dev/null 2>&1 || fail+=("test failed against current head: $tcmd")
    local head_after; head_after="$(git -C "$wt" rev-parse HEAD)"
    [ "$head_after" = "$head" ] || fail+=("--test moved HEAD ($head -> $head_after) — approval is stale (RE-RUN THE CHECKER)")
    # finding #4: a test that writes non-ignored artifacts leaves the tree dirty; don't report PASS: clean.
    [ -z "$(git -C "$wt" status --porcelain)" ] || fail+=("--test left the worktree dirty (uncommitted artifacts) — gitignore them or clean up")
  fi
  if [ "${#fail[@]}" -eq 0 ]; then
    echo "PASS: head=$head clean, non-empty vs $base, checker-current${tcmd:+, tests green}"
    return 0
  fi
  printf 'REFUSE:\n'; printf '  - %s\n' "${fail[@]}"; return 1
}

if [ "$selfcheck" -eq 1 ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init -q -b main
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name t
  echo a > "$tmp/f"; git -C "$tmp" add -A; git -C "$tmp" commit -qm c1
  git -C "$tmp" checkout -qb feat; echo b >> "$tmp/f"; git -C "$tmp" commit -qam c2
  head2="$(git -C "$tmp" rev-parse HEAD)"
  gate "$tmp" main "$head2" "true" >/dev/null       && echo "selfcheck: clean+matching -> PASS ok"      || { echo "selfcheck FAIL: should have passed"; exit 1; }
  echo c >> "$tmp/f"; git -C "$tmp" commit -qam c3   # head moves -> stale checked-sha
  gate "$tmp" main "$head2" "true" >/dev/null        && { echo "selfcheck FAIL: stale sha should refuse"; exit 1; } || echo "selfcheck: stale-sha -> REFUSE ok"
  echo dirty >> "$tmp/f"                              # dirty tree
  gate "$tmp" main "" "true" >/dev/null              && { echo "selfcheck FAIL: dirty should refuse"; exit 1; } || echo "selfcheck: dirty-tree -> REFUSE ok"
  echo "selfcheck: ok"; exit 0
fi

[ -n "$worktree" ] || { echo "need --worktree PATH (or --selfcheck)" >&2; exit 2; }
gate "$worktree" "$base" "$checked_sha" "$test_cmd"
