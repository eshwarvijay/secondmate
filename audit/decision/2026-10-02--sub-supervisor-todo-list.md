## 2026-10-02 — Single insertion point at 'The loop' header; non-conflation with progress-ledger.py verified by checker

**What the maker decided:** Insert exactly one new paragraph immediately after the `## The loop
(executed inside the dispatched sub-supervisor's own context — steps 1-11)` header in
`skills/secondmate/SKILL.md` (before the "Maker prompt closing boilerplate" subsection), requiring
every dispatched sub-agent-supervisor — solo or batch — to seed a TodoWrite checklist (one pending
item per named SOP step: Plan Committee 0a-0d, then Triage, Spawn, Guard, Check, Gate, Hold,
Integrate, Teardown, Audit trail, Lesson feedback) immediately after claiming/recording the `claimed`
progress-ledger checkpoint and before Triage, updating each item's status as it progresses. This
location was chosen (via the Plan Committee + adhd convergence) over two alternatives — the "Roles"
section's sub-agent-supervisor bullet (too conceptual/early, not where procedural steps live) and
"Dispatch mechanics — solo and batch" (would require touching both the solo numbered list AND the
batch lettered list separately, i.e. two edit sites, violating the task's single-insertion-point
constraint) — because "The loop" header is the one place both solo and batch dispatch instructions
converge on ("run the existing solo SOP completely untouched") before step 1 begins. A matching 6-line
note was added to `docs/ARCHITECTURE.md` per this repo's own CLAUDE.md doc-sync requirement.

The instruction explicitly: (a) scopes to the sub-agent-supervisor role only, excluding the maker
(round-state.md/feature-list.json) and the checker (stateless per round); (b) states it does not
replace, feed into, or duplicate `progress-ledger.py`'s cross-task-visible checkpoint mechanism, which
keeps working unchanged; (c) mirrors the SOP's own step names rather than inventing a contiguous
renumbered sequence (the maker verified the file's own loop headings are `1,2,3,4,5,6,8,9,10,11` —
step 7 is already absent — and did not introduce or renumber anything); (d) includes a fallback
("if TodoWrite isn't available, keep an equivalent plain checklist") grounded in a real observation
from this very task — the supervisor found no loadable `TodoWrite` tool via `ToolSearch` in its own
harness instance, confirming TodoWrite availability is harness-dependent, not guaranteed.

**What the checker found:** `pass`, zero findings. The checker (gpt-5.6-terra, cross-model, run per
the HERDR_ENV strict visible-pane rule) explicitly probed and confirmed: only 2 files changed
(`git diff --name-only`), no scripts/plugin-manifest/enforcement machinery touched, `progress-ledger.py`
itself byte-unchanged (`git diff --quiet` on that file), no duplicate/scattered insertion, and correct
exclusion of the maker/checker roles.

**Gates:** `verify-gate.sh` returned `PASS` (checked-sha `542436f`, clean, non-empty vs `main`,
checker-current) — confirmed by the supervisor with an independent fresh re-run, not just the fork's
report. One human hold (`a5f2cada`) was opened and genuinely answered externally (`merge`) — the
supervisor independently verified the answer in the raw `decisions.jsonl` ledger (not just the
dispatcher's relay) before proceeding to Integrate, per the never-self-answer / never-trust-secondhand
rule.

**Residual, explicitly out of scope:** `bin/session-activate.sh`'s SessionStart hook text does not
yet mention TodoWrite-seeding. Left untouched deliberately — flagged as a possible future follow-up,
not a defect in this task's scope.
