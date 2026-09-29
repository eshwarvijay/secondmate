## 2026-09-30 — batch-hold-scaling: structural batch-id binding + verdict.py reuse; human-approved merge

## What the maker decided
- Extended `bin/hold.py` with a new `--entries-file` consolidated batch-hold path carrying a
  `{task_id, checked_sha, checker_verdict_path}` list, hard-capped at 10 entries, rather than adding a
  second, parallel hold mechanism — kept the pre-existing single-task `--sha` anti-reattach binding
  completely untouched (a human had explicitly required this guarantee survive as an extension, never a
  replacement).
- Sourced each batch entry's digest by loading `bin/verdict.py` as a module and calling its own
  `read_verdict_with_envelope`/`VALID` enum directly, instead of writing a second, parallel envelope
  parser — a deliberate reuse decision surfaced by the checker in round 2 and adopted by the maker in its
  round-2 fix.
- Chose to bind `--batch-id` immutably per task-id at its earliest use (write-time rejection of rebinding,
  read-time exclusion of internally-inconsistent row histories) as the *structural* half of the
  restart-misrouting fix, and UUID minting (documented in SKILL.md) as the *practical* half — explicitly
  declined to build a distributed uniqueness registry to close the residual cross-process-collision gap
  completely, on the grounds that it would be new machinery beyond this task's stated "no 1000-task
  hardening" scope boundary. This was my own explicit instruction in the round-2 fix plan, and the maker's
  documentation of the honest limitation (rather than overclaiming a full fix) was verified faithful by the
  round-3/round-4 checker passes.
- Kept the existing single-task delegation trigger (trigger A) mechanically unchanged — still self-merges
  via its own individual hold, still emits `SM_DONE_MERGED` — rather than folding it into the new batch
  mechanism as a "batch of one". The maker flagged this itself in its round-1 handoff as a deliberate
  judgment call to keep the diff minimal and the already-tested single-task path untouched; I did not
  challenge it, and no checker round raised it as a defect, so no escalation was needed on this point.

## What the checker found (and how each was resolved)
1. Round 1 (6 findings, all fixed in commit `94ba8b7`): missing verdict-artifact validation, thin digest,
   unenforced N=10 cap, silent classification dedup, no batch/solo-task correlation on restart, and two
   modified hooks with fake/no selfcheck.
2. Round 2 (2 findings, both fixed in commit `8715412`): the round-1 batch-id fix didn't structurally
   prevent a cross-batch-id collision; envelope validation was too permissive.
3. Round 3 (1 finding, fixed in commit `c63f2bcd5e3efdba11574974a3cef978700a91ec`): a documentation
   overclaim contradicting the honestly-stated residual limitation — resolved by rewording, no code change.
4. Round 4: clean pass on the full accumulated diff.

## Gates auto-approved vs. escalated, and why
- All 4 checker verdicts were read via `bin/verdict.py`'s deterministic exit code, never checker prose —
  no ambiguous/error/refused verdict occurred, so no escalation was needed at the Check step.
- `bin/verify-gate.sh` PASS was auto-approved (mechanical: clean tree, non-empty diff vs. main, checked-sha
  matched HEAD) — nothing to escalate.
- The merge decision itself was **never** auto-approved by me — I opened a durable hold
  (`bin/hold.py`, id `4899dfd4`) and waited for a real human `approve`, which I independently verified
  against the raw `decisions.jsonl` ledger entry (matching SHA `c63f2bcd5e3efdba11574974a3cef978700a91ec`)
  before running `merge-sequencer.sh`, rather than acting on the dispatcher's relayed claim alone.
- No `SM_STUCK_NEED_HUMAN` or `SM_REFUSED` path was hit; the task reached `SM_DONE_MERGED` cleanly.

## Residual, deliberately-accepted limitation (not a defect)
Two independent dispatcher processes coincidentally minting the identical `--batch-id` string is not
structurally prevented — only made practically negligible via UUID minting. This is documented
consistently in code comments, `docs/ARCHITECTURE.md`, `README.md`, and `skills/secondmate/SKILL.md`, and
was explicitly named out-of-scope in the resolved task spec ("no 1000-task hardening", "the cap is an
explicit 10, hard, not tunable"). Flagging here so it isn't rediscovered as a "new" bug later.
