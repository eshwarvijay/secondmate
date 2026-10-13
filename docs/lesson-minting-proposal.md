# Proposal: let a sub-supervisor mint a brand-new lesson

Status: **proposal only.** Until a human reviews this and manually applies part (a) to
`skills/secondmate/SKILL.md`, `bin/lesson-lookup.py mint` has no sanctioned caller in the live SOP.
This is deliberate, proposal-first sequencing: the capability ships now so it can be exercised and
reviewed; the doctrine change that would actually invoke it does not ship until a human adopts it.

Also deliberately out of scope this round: `README.md` and `docs/ARCHITECTURE.md` are **not** updated
by this task, even though `CLAUDE.md`'s general pre-push doc-sync rule would normally require it. That
rule covers shipped, SOP-wired behavior; `mint` is explicitly not SOP-wired yet (see above), so there is
nothing live to document. This proposal is the carve-out, pending human adoption of part (a) below.

## (a) When a sub-supervisor may mint, not just tag

Today, step 11 of the SOP lets a sub-supervisor `tag` an *existing* lesson as helpful or harmful,
on direct, specific, this-task evidence -- never on a hunch. This proposal extends that same
evidence bar to also permit minting a brand-new lesson, in the same step-10/11 primary-checkout
commit, when the task surfaced a pattern no existing lesson covers.

The exact paragraph a human would paste into SKILL.md's step 11:

> A sub-supervisor may also **mint** a brand-new lesson in this same commit, under the identical
> evidence bar step 11 already applies to tagging: only on direct, specific, THIS-TASK evidence of a
> new recurring failure pattern or a concretely experience-earned habit -- never on a hunch, and
> never speculatively ("this might help someone else later"). Before minting, re-run the normal
> `bin/lesson-lookup.py --task "<description>"` lookup and confirm no existing lesson already covers
> the pattern -- mint is for a genuinely new pattern, not a rephrasing of one that already exists.
> Mint with `bin/lesson-lookup.py mint --file <draft.md> --category <cat>`, setting the draft's
> `earned-in` to this task's own task-id. Mint at most once per distinct failure pattern per task --
> several unrelated patterns in one task may each get their own mint, but the same pattern observed
> twice in one task is one mint, not two.

## (b) Curation and retirement

A lesson becomes a **retire-candidate** -- surfaced to a human for manual review, never auto-deleted
and never auto-relocated by any code -- when either of the following holds:

- `harmful_count > helpful_count`, after at least 3 total tags (`helpful_count + harmful_count >= 3`).
  Fewer than 3 tags is too little signal to act on; a lesson that has crossed that bar and is net
  harmful more often than it helps is worth a human looking at it.
- The lesson received **zero injections across the last N recent task-ids** in the injection ledger
  (`.secondmate/lesson-injections.jsonl` / `SM_LESSON_LEDGER`), where **N=10 is the default**. N is
  human-tunable, not hardcoded in any script -- a human reviewing retire-candidates picks the N that
  fits how much history is available and how fast this repo accumulates tasks.

This round ships doctrine prose only. No script computes "retire-candidate" status, no script flags
or moves lessons, and no automated process acts on either condition above. A human applying this
amendment decides, by hand, what counts as "surfaced for review" (a report, a manual
`bin/lesson-lookup.py` scan, or whatever mechanism they choose) and what to do with a flagged lesson
(edit it, retag it, delete it, or leave it as-is).
