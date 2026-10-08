## 2026-10-08 — wire-budget-aware-sop: SKILL.md checkpoint cost/self-estimate flags + pane-reaper watchdog wiring

## wire-budget-aware-sop — flow

Solo dispatch, full rigor tier (checker + verify-gate + human hold), as mandated by the task itself since
it edits SKILL.md — the SOP every future dispatched sub-supervisor reads.

**Plan Committee.** 0a: 5-frame `adhd` (regulator, 3am on-call, inversion, competitor/red-team,
speedrunner) run as 5 fresh, non-fork Agent-tool calls — deliberately not `fork`, to avoid the
fork-contamination risk the task itself flagged (a fork would have inherited this whole dispatch's "run
the entire SOP" framing). 0b: 6-model `plan-committee.sh` (deepseek-r1, qwen3-80b, qwen3-coder, kimi-k3,
mistral-large3, glm5) against a task-scoped `--out-dir .secondmate/planning/wire-budget-aware-sop`
(the shared top-level `planning/` dir had unmarked legacy loose files from an older convention, so
plan-committee.sh correctly refused the default dir and a task-scoped dir was used instead). 0c: every
planner's "Probes for Supervisor" was answered directly from the repo (herdr's own CLI exposes no
cost/activity field at all; `claim-ledger.py` stores no pane-id mapping; `pane-reaper.py quiet` has no
`--pane` filter) — zero escalations needed. 0d: routed to a **Claude maker** (judgment-heavy: finding
exact call sites, splicing sentences without rewriting paragraphs, running real end-to-end verification),
per the "Complex" criteria.

**Spawn.** `herdr worktree create` → workspace `w6C`, branch `sm/wire-budget-aware-sop`, root pane
`w6C:p1`. Marked via `mark-maker.sh`, skills synced, caffeinate guard started.

**Maker, round 1.** Edited the 4 `progress-ledger.py record` checkpoint call sites (Solo dispatch steps
1/3/4, Batch dispatch steps a/c) to add `--cost`/`--tokens`/`--duration-seconds` (only when at hand,
reusing the existing `log-round.sh` "never scrape or parse" anchor phrase) and `--still-achievable
{yes,no}`+`--note` (derived from a signal the SOP already evaluates at that checkpoint). Edited the
staleness-watchdog section to call `bin/pane-reaper.py observe` (new — `quiet` needs ≥2 prior polls to
ever report anything, and nothing called `observe` before) then `quiet --threshold-seconds N`, filtering
output to this dispatch's known pane ids, splicing a quiet-pane hit into the existing stale-hit relay
sentence. Also corrected 2 stale factual lines in README.md/docs/ARCHITECTURE.md that claimed
`pane-reaper.py` was "not wired into any dispatcher" (now true that it is, via the watchdog). Committed
`f048c39`.

**Check, round 1 — FAIL (real bug).** Visible herdr checker pane `w6C:p2`, pi/gpt-5.6-terra, lenses
`qa/test-reality`+`reverse-engineer/intent-vs-impl`+`research/groundedness`. Confirmed finding: the SOP's
own example `grep -F -e "<pane_id>"` filter does substring matching, not exact matching — a known pane
"p1" would wrongly also match an unrelated pane "p10" sitting in the same shared `pane-reaper.py quiet`
ledger output, misattributing another dispatch's quiet-pane hit. Synthesized a fix plan (never fixed
inline) and routed it back to the maker.

**Maker, round 2.** Anchored the filter to the quoted `"pane_id": "<id>"` key form `pane-reaper.py`
itself emits (`json.dumps({"pane_id": pane_id, ...})`), which cannot substring-collide the way a bare id
can. One line + its comment changed, nothing else touched. Re-verified with a synthetic p1-vs-p10
fixture proving the old form matches both and the new form matches only the exact one. Committed
`4168e4e`.

**Check, round 2 — PASS.** Same pane, re-run with output tee'd to a file (the first round-2 run exited 0
cleanly but its written analysis was lost to the pane's scrollback/alternate-screen before capture — a
known herdr limitation documented in the herdr skill itself; re-ran rather than trust an unseen result).
Checker independently reproduced the round-1 bug against the OLD form, confirmed the NEW form excludes
`p10`/`p1x` while matching `p1` exactly, confirmed the round-2 diff touches only the one line + comment,
confirmed round-1 content and all `bin/` scripts/trigger-test/hold-merge-mechanics are untouched. One
genuine spec-ambiguity noted (JSON-escaped/non-ASCII pane ids) — a pre-existing limitation, not introduced
by this task, correctly not treated as a defect.

**Gate.** `verify-gate.sh` → PASS at `4168e4e2b69f258e0e8c483a474867529b2aa597`.

**Mid-task incident.** A transient ENOTFOUND killed the process right as round-2's Check was about to
launch. The coordinator resumed with full context; before continuing, independently re-verified
claim-ledger/progress-ledger/worktree/herdr-workspace state from scratch rather than trusting the
pre-crash notes — all confirmed intact.

**Hold.** Opened `a2ef39d4` (single-task, bound to the checked SHA). Coordinator later reported it
answered "approve" — independently verified by reading `decisions.jsonl` directly (not trusting the
report at face value): a genuine `{"ev":"answer","id":"a2ef39d4","a":"approve"}` row exists, and
`hold.py open` no longer lists it.

**Integrate.** `merge-sequencer.sh` → merged to `main` as `5cee8f6b3444affa7927703ff900c2274fffe61c`,
pushed to origin. (Its advisory version-bump reminder was treated as non-blocking: this is a SOP-prose-only
change, consistent with how the immediately preceding merge — a maker-model swap — also landed with no
plugin.json version bump.)

**Teardown.** Checker pane closed, worktree+workspace `w6C` removed, branch deleted, claim released
(token from the original claim call), `teardown-check.sh` reports fully clean. Caffeinate guard stopped
(solo dispatch, no sibling tasks).
