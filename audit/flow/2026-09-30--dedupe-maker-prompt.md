## 2026-09-30 — dedupe-maker-prompt: consolidate 7 duplicate maker-prompt closing boilerplate sites in SKILL.md

## Task
dedupe-maker-prompt — consolidate 7 duplicated "maker prompt closing boilerplate" sites in
`skills/secondmate/SKILL.md` (round-state handoff atomic-write instruction + previous-round-handoff
injection + lesson-lookup injection) into one canonical, named reference block, replacing each site
with a short pointer. Triggered by a plan-committee audit that found this exact drift had already
caused a real bug (commit 347677a, a 5-site sweep that missed 2 other sites earlier).

## Triage
Ship task, full rigor (checker + verify-gate + human hold). Skipped the heavyweight 6-model Plan
Committee / adhd ideation step — the parent task was already fully specified (exact goal, exact
constraints, exact verification method, and even a concrete suggested mechanism), which per the
global CLAUDE.md's own "skip divergent ideation for closed/mechanical work" guidance made a fresh
6-planner committee redundant overhead rather than useful signal.

## Maker routing
Claude maker via herdr (visible pane, `sm-dedupe-maker-prompt`), not the pi/simple route — chosen
because the task required careful, judgment-heavy multi-site textual editing across a large file with
an explicit "no silent loss of instruction content" risk, better suited to Claude's reasoning than a
well-specified-but-mechanical pi task.

## Rounds
- Round 0 (pre-check, caught by supervisor before spending a checker round): maker's first pass
  (commit 03f20c6) introduced a stray/misplaced closing backtick on 2 lines, breaking the code-span.
  Supervisor caught this by direct inspection and routed a one-line fix back to the maker (commit
  e360182) before invoking the checker at all.
- Round 1 (checker, gpt-5.6-terra, visible herdr pane per the strict no-headless rule): verdict=fail.
  Two real findings: (a) 3 of the 7 pointers claimed the canonical block was "defined above" when it
  is physically below those 3 sites (they live in the earlier "0d — route the maker" section); (b)
  the two Claude-maker call sites lost byte-fidelity — dropped markdown-emphasis asterisks around one
  sentence, and reordered the "Do NOT invoke /loop-task or secondmate" instruction relative to the
  injected round-state/lesson content.
- Fix round: maker reworded all 7 pointers + the canonical block's own intro to be position-agnostic
  (names the block by heading instead of claiming above/below), and restored the original relative
  instruction order at the two Claude sites. Explicitly documented, in its round-state handoff, the
  one deliberate judgment call it made (NOT restoring the asterisks, since 5 of 7 sites never had
  them) rather than silently normalizing it. Commit 0d1d61f.
- Round 2 (checker): clean pass, `{"verdict":"pass","findings":[]}`, verdict.py exit 0.

## Outcome
verify-gate PASS at sha `0d1d61feb1033e059112bb272aee4daa2601ca6b` vs `main`. Human hold `f799ead7`
answered `yes` (SHA-bound). Merged to main as `fc9c4de7fa693c42f6470fc8ddcaa75c000fb09a`, pushed to
origin. Worktree/branch/herdr pane/claim all torn down cleanly (teardown-check.sh: clean on all four).

## Scope side-checks
- `bin/session-activate.sh`: grepped, no restatement of this boilerplate found — left untouched.
- `docs/ARCHITECTURE.md`: only a passing mention of `round-state.md`'s path/purpose in the loop-guard
  restart-signal context (~lines 117-119) — not a restatement of the full boilerplate — left untouched
  per the task's own "note explicitly if absent" instruction.
- No `.claude-plugin/plugin.json` version bump: judged unnecessary since this is pure editorial
  restructuring inside SKILL.md with no behavior/command change (same judgment call the task itself
  suggested defaulting to).
- No README.md/ARCHITECTURE.md doc-sync edit made beyond the SKILL.md change itself: this task touched
  neither bin/ scripts, config vars, nor the version badge — only SKILL.md's internal duplication.
