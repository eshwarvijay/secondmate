## 2026-09-30 — Shell-safe prose over the plan's own drop-in draft; no automated enforcement, human-approved merge

**What the maker decided:** Land both Devin-AI-comparison gaps (test-tampering ban;
git-hygiene tightening) as one prose paragraph inserted between the block's existing
premature-victory-guard paragraph and its session-startup-checklist paragraph — matching
adhd's synthesized placement rationale (groups with other "before/during DONE" conduct
paragraphs; doesn't interleave into the round-state.md format-instruction paragraph; can
name "Blocked section" using the name already established earlier in the block). The maker
overrode the plan's own literal drop-in wording (which still contained backtick code-spans,
literal quoted command strings, and a bulleted two-line structure) in favor of continuous,
shell-inert prose with a numbered (1)/(2) structure — a real, justified deviation from the
plan, not scope creep: the plan's own hard-constraint #3 required shell-safety, and the
maker's chosen wording is what actually satisfies that constraint where the plan's own
illustrative draft would have failed it. It also synced `docs/ARCHITECTURE.md`'s "Implement
(guarded)" step's content enumeration and "Guards against" line, and deliberately left
`README.md` and `.claude-plugin/plugin.json` untouched, both per explicit repo precedent
found during planning (`audit/decision/2026-09-30--loop-harness-upgrades.md`) rather than by
omission.

**What the checker found:** Nothing — pass, zero findings, one round. It independently
re-verified (rather than trusting the diff hunk alone) by reading the full current block, all
8 call-site pointer occurrences, and running `git diff --check` plus a literal grep for `"`,
backtick, and `$(` across only the new lines. It explicitly named the residual risk as
behavioral, not implementation: "an individual maker may disregard a prompt-only guardrail"
— accepted as the honest limitation of a prompt-layer-only control, consistent with the
task's own explicit non-goal of not building automated/hook-level enforcement this
increment.

**Gates:** Verify-gate PASS, checked-sha-bound, re-confirmed with zero drift immediately
before merge (no commits landed on the branch between checker approval and merge). Human
hold `6dfd1cdf` was NOT self-answered — genuinely answered by a human via the coordinator
relaying the decision; per the SOP's explicit "do not take my word for it" instruction, I
independently re-verified against the raw `decisions.jsonl` ledger (not the coordinator's
message) before treating it as authorized, and only then ran `merge-sequencer.sh`.

**Scope decisions escalated vs. resolved locally:** None of the six planners' probes were
escalated to the human — all were answered from the task's own explicit text (this is prompt-
text-only, no new bin/ script or enforcement mechanism; both gaps are meant as defense-in-depth
alongside existing downstream detectors) or from repo precedent (version-bump-skip
convention). The only genuine human decision in this task was the terminal merge/reject/revise
hold, which is exactly where the SOP places it.

**Process finding worth flagging for future tasks:** constructing a maker/checker prompt that
embeds literal markdown backticks and double-quoted example strings inside a bash
double-quoted argument is a real, repeatable trap — bash's lexer quote-balances characters
even inside heredoc bodies with a quoted delimiter (confirmed empirically mid-task: an odd
count of literal apostrophes in prose broke `bash -n`). Worked around by writing prose
sections to plain files and `cat`-ing them into the final argument rather than embedding them
in heredocs or inline strings, and by preferring `launch-checker.sh --addendum FILE` over
`--addendum-text "..."` once the addendum text itself contained embedded double quotes. No
`bin/` change proposed for this — noting it here as a supervisor-construction gotcha, not a
tooling gap, since the fix is "write to a file first," always available without new tooling.
