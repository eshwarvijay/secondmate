## 2026-09-30 — One canonical boilerplate block + 7 pointers; fixed direction wording and byte-fidelity drift on checker fail

## Decision
Consolidated 7 verbatim-duplicated "maker prompt closing boilerplate" sites in
`skills/secondmate/SKILL.md` into one canonical `### Maker prompt closing boilerplate` subsection near
the top of "## The loop" section, with each of the 7 original sites replaced by a short, direction-
agnostic pointer to it. No build step, template engine, or generated-file pattern was introduced —
stays hand-authored plain markdown, per explicit instruction.

## What the maker decided
- Placed the canonical block at the top of "The loop" — matching the task's own suggested location —
  even though 3 of the 7 call sites (in the earlier "0d — route the maker" section) physically precede
  it. Resolved the resulting "defined above" inaccuracy (see below) by making the pointer wording
  name the block instead of claiming a relative position.
- Deliberately did NOT restore markdown-emphasis asterisks that had wrapped one sentence at the two
  original Claude-maker sites only (5 of the other duplicate sites never had them) — treated as a
  pre-existing cosmetic inconsistency, not something to re-introduce into the canonical block.
  Explicitly surfaced this judgment call rather than silently normalizing it.

## What the checker found
- Round 1 (fail): (a) 3 of the 7 pointers said "defined above" — factually wrong for those 3 sites
  since the canonical block sits below them in the file; (b) the two Claude-maker sites were not
  byte-identical to their originals — lost the emphasis asterisks (see above) and reordered the
  "Do NOT invoke /loop-task or secondmate" instruction to after the folded-in pointer instead of
  before it, changing when a reader encounters that constraint relative to the round-state/lesson
  content.
- Round 2 (pass): both findings fixed and verified; markdown fence/backtick integrity confirmed intact
  (`git diff --check` clean, CommonMark parse via markdown-it succeeded); scope containment confirmed
  (only SKILL.md changed; trigger test / "Not for" / dispatch-standard-path sections untouched).

## Gates
- verify-gate: PASS, checked-sha `0d1d61feb1033e059112bb272aee4daa2601ca6b` matched worktree HEAD
  exactly, tree clean, non-empty diff vs main.
- Human hold `f799ead7` (SHA-bound to the checked sha): answered `yes` by a genuine human decision —
  supervisor did not self-answer, and independently verified the answer directly against the
  `decisions.jsonl` ledger (not just the relayed message) before merging.

## Escalations
None required beyond the standard human merge-approval hold — no OPEN DECISIONs surfaced during
triage (the task was fully specified going in), and no ambiguous/error/refused checker verdicts
occurred.

## Auto-approved without escalation
- Skipping the 6-model Plan Committee / adhd step for this task (closed/mechanical, per global
  CLAUDE.md's own skip criterion) — a supervisor judgment call, not itself a merge-gating decision, so
  not escalated.
- No `.claude-plugin/plugin.json` version bump and no README.md/docs/ARCHITECTURE.md edits beyond
  SKILL.md itself — judged as no behavior change and no bin/config/version-badge impact.

## Lesson feedback
No injected lesson from this task's lesson-lookup.py output was directly, specifically evidenced as
helpful or harmful during this task (the round-1 failure was caught by direct checker review, not
traceable to any one injected lesson being followed or ignored) — left untagged per the "don't tag on
a hunch" rule.
