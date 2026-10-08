## 2026-10-09 — pi-nested-context-files: set-u-safe splice + -type f fixes; two integration escalations resolved by human/dispatcher

## pi-nested-context-files — decision

**What the maker decided**: implement the nested-context-file discovery as a single named, reusable
"Nested context-file args" block in `skills/secondmate/SKILL.md` (DRY, matching the existing "Maker
prompt closing boilerplate" convention) rather than duplicating find/collect logic at each of the 4
pi-maker launch sites — chosen specifically because the task's own constraints forbade creating any new
file/script besides SKILL.md.

**What the checker found**: round 1 — 2 confirmed real bugs, not style nits: (1) the plain
`"${nested_ctx_args[@]}"` splice crashes with "unbound variable" under a `set -u` bash session on bash
3.2.57 (macOS's shipped default) whenever the array is empty — i.e. in the common, everyday case of zero
nested context files, breaking all 4 launch paths; (2) the `find` predicate matched by basename only
(`-iname`, no `-type f`), so a nested directory happening to share a context-file's name would be wrongly
collected and passed to `--append-system-prompt`. Round 2 — pass, zero findings, both fixes verified
present at all 4 sites and the single canonical block.

**Supervisor's own verification, independent of both maker and checker**: before writing any plan, ran a
real `pi` invocation with `--append-system-prompt <fixture>` and confirmed live that pi injects file
*contents*, not just the path — this is the core mechanism the entire task rests on, and it was proven
empirically rather than assumed from `pi --help` text alone. Also personally discovered and fixed a find
+ `-prune` + `-mindepth` interaction bug (prune silently never fires under mindepth) while validating the
scope boundary, and handed the corrected snippet to the maker directly to prevent it from independently
rediscovering the same trap — this trap was separately flagged as the "most dangerous assumption" by the
deepseek-r1 planner in the committee stage, so pre-empting it saved a round.

**Gates auto-approved vs. escalated**: all ~12 cross-planner probes from the Plan Committee stage were
resolved and auto-approved without escalation — each was answerable from the repo's own existing
conventions, the task's own explicit text, or `pi`'s own documented/verified behavior (e.g.
`--append-system-prompt` is purely additive, so no merge/override semantics question existed; no size/depth
cap was invented since none was requested and this repo's worktrees are small; the worktree is the
maker's own already-trusted checkout, so no new security/trust-boundary flag was warranted). Nothing was
escalated at the planning stage.

The merge/integration decision itself (hold `25765766`) WAS escalated to a human, per the SOP's "every
human-gate decision is durable, never self-answered" rule — approved `"yes"`, independently re-verified
against the raw ledger three separate times across the task's lifecycle (never taken on a resume
message's word alone). Two further process-level escalations happened during integration, both resolved
by direct human/dispatcher action rather than by this task working around them: (1) the first merge
attempt was blocked by Claude Code's own auto-mode permission classifier ("Modify Shared Resources") —
reported rather than bypassed; the human then granted the permission directly via `/permissions`; (2) the
retry then hit `merge-sequencer.sh`'s own clean-state refusal over 3 pre-existing, out-of-scope `.lock`
files in the primary checkout (leftover from an unrelated prior task) — reported rather than deleted
unilaterally; the dispatcher then committed a one-line `.gitignore` fix (`934f86a`) directly to main to
clear it. Both interventions were genuine human/dispatcher actions, independently re-verified by this
task before each retry, never self-authorized.

**Lesson signal**: "commit-before-done" and "mutation-test-your-tests" were both directly exercised and
reinforced by this task — the maker's round-1 and round-2 verification work matched the mutation-testing
lesson's prescription almost exactly (deliberately reverting each fix and confirming the test suite
catches the regression), and both rounds ended with an actual `git commit` as the literal final action,
matching commit-before-done. "stay-in-literal-scope" also held across both rounds and the supervisor's
own handling of the stray `.lock`-file blocker (reported instead of unilaterally deleting out-of-scope
files).
