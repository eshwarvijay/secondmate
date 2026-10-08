## 2026-10-08 — wire-budget-aware-sop: substring-collision bug caught+fixed round 1->2; hold answer independently re-verified

## wire-budget-aware-sop — decision

**What the maker decided.** Minimal-diff, anchor-reuse approach throughout (converged on by the Plan
Committee's 5-frame adhd, specifically the speedrunner/3am-on-call frames): point new instructions at
exact phrases SKILL.md already contains ("a herdr pane's own cost/elapsed display ... never scrape or
parse for them"; "relay it to the human verbatim") rather than writing new paragraphs. `--still-achievable`
was deliberately NOT wired as an independent judgment call — it's attached to a signal the SOP already
evaluates at each checkpoint (triage/claim result, maker-started, checker verdict, gate result), so no new
reasoning burden was introduced. Declined to add a `--pane-id` filter flag to `pane-reaper.py` itself
(the task's own "no further defensive-coding sweep" boundary) — chose a SOP-prose-level output filter
instead, since the sub-supervisor already holds its own pane ids as local values and needs no new lookup
machinery.

**What the checker found.** Round 1: one real, confirmed bug — `grep -F -e "<pane_id>"` substring-matches
rather than exact-matches, so a dispatch's own pane "p1" would wrongly also catch an unrelated "p10"
sitting in the same shared ledger and misrelay someone else's quiet-pane hit to the human. This is exactly
the kind of thing a prose-only SOP edit can get wrong without anyone noticing until it's live — the fix
(anchoring to the quoted `"pane_id": "<id>"` key form) was verified end-to-end with a synthetic
p1-vs-p10 fixture, not just reasoned about. Round 2: pass, with one correctly-non-blocking spec ambiguity
noted (JSON-escaped/non-ASCII pane ids) that predates this task and wasn't introduced by it.

**Gates.**
- Verify-gate: auto-run, PASS at the exact checked SHA — no escalation needed, deterministic criteria
  unchanged by this task per its own constraint.
- Human hold `a2ef39d4`: escalated as required (never self-answered). Independently re-verified the
  answer against the raw `decisions.jsonl` ledger rather than trusting the coordinator's relay at face
  value — found a genuine, SHA-bound `{"a":"approve"}` answer record, consistent with `hold.py`'s own
  "answer must match the held SHA" validation (an answer for a different code state would have been
  rejected outright, so its presence in the ledger is itself evidence it matched).
- Doc-sync: the maker caught 2 now-false claims in README.md/docs/ARCHITECTURE.md ("pane-reaper.py ...
  not wired into any dispatcher") and corrected them as part of its own round-1 commit — a factual
  correction, not scope creep, and reviewed clean by the checker on exactly that point.
- Version bump: NOT done, deliberately. This is a SOP-prose-only change with no new script flag/default;
  the merge-sequencer's reminder is boilerplate advisory, and the immediately preceding merge in this
  repo's own history (a maker-model swap) set the precedent of not bumping for every merge.

**Process note.** A real reliability gap surfaced and was worked around rather than ignored: round 2's
first checker run exited 0 cleanly, but its full written analysis never made it into the herdr pane's
scrollback (lost to the pane's alternate-screen behavior, a limitation the herdr skill's own docs already
warn about). Rather than accept an unseen "it passed" on faith, the identical review was re-run with
output tee'd to a file for a reliable capture before trusting the verdict.
