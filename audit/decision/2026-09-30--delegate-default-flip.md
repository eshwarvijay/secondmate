## 2026-09-30 — Fold fan-out into the standard path; fix a real HERDR_ENV-conditional spawn bug the checker caught in round 1

## What the maker decided

- Restructured `skills/secondmate/SKILL.md` so there is exactly ONE path once the trigger test fires:
  claim → dispatch a fresh sub-agent-supervisor (solo or batch, same mechanism, differing only in
  fan-out size) → the dispatcher's job narrows to watch/parse/relay/stay-free. Split the "Roles" section
  into top-level supervisor (dispatch-only) vs sub-agent-supervisor (runs the SOP). Renamed the old
  opt-in "Fan-out" section to "Dispatch mechanics — solo and batch" and removed "opt-in"/"two independent
  triggers" framing throughout, while preserving every piece of its hard-won correctness content
  verbatim in substance: claim-first-then-`SM_REFUSED:claim-failed`, never-self-answer-a-hold, the N=10
  hard cap (non-tunable), batch `--entries-file`/digest-from-real-verdict mechanics, and the
  `progress-ledger.py` staleness watchdog via `ScheduleWakeup`. Added the previously-missing
  `progress-ledger.py record` checkpoints to the solo path (only the batch path had them documented
  before this task).
- `bin/progress-ledger.py`: judged no code change necessary. Verified via `--help` on every subcommand
  (record/latest/status/stale/ready/selfcheck) that `--batch-id` is already optional on `record` — a solo
  dispatched task can record the exact same four checkpoints a batched one does with the existing CLI.
  This was accepted as-is rather than adding speculative flags the SOP change didn't need.
- Synced `docs/ARCHITECTURE.md` (Roles table, "The loop" mermaid, stage-by-stage intro, dropped the stale
  "next evolution... not yet wired into the loop" framing for the fan-out primitives section),
  `README.md` ("How it works", version badge 0.1.37→0.1.38), `.claude-plugin/plugin.json` (version bump
  to match). Reviewed `bin/session-holds.sh` and judged no change needed — it renders `hold.py open`'s
  output regardless of who opened the hold, so it's unaffected by who dispatches.

## What the checker found (and every gate outcome)

- **Round 1 — FAIL, auto-approved fix-and-reloop (no escalation needed).** Checker (running in a visible
  herdr pane per the strict HERDR_ENV=1 rule) found: (1) `bin/session-activate.sh`'s rewritten banner
  unconditionally told a dispatched sub-supervisor to run `herdr worktree create`, but SKILL.md's own
  Spawn step documents `new-worktree.sh` for headless/non-herdr dispatch — a real, confirmed bug in the
  exact text this task rewrites, not a false positive or scope creep; (2) the banner's own embedded
  `--selfcheck` asserted only a subset of its live policy claims, leaving several claims (including the
  HERDR_ENV-conditional spawn rule) unguarded against silent future regression — this is precisely the
  risk a parallel plan-committee audit (kimi-k3's finding, relayed by the coordinator mid-task) flagged
  independently: a banner rewrite could drift from what its own selfcheck actually tests. Both were
  legitimate, in-scope findings (the maker was already instructed to keep banner and selfcheck
  consistent) — routed a fix plan back to the same task-scoped maker, never fixed inline as supervisor.
- **Round 2 — PASS, no findings.** Maker fixed both: reworded the banner's spawn instruction to mirror
  SKILL.md's own HERDR_ENV=1-vs-headless distinction, added targeted `--selfcheck` assertions for the
  corrected wording plus the never-self-answered-hold and narrowed-dispatcher-job claims, and
  mutation-tested them (reverted the fix in place, confirmed the new assertions failed, restored,
  confirmed green) before committing. Checker independently re-verified via its own mutation probes on a
  scratch copy, plus re-checked the trigger test / "Not for" boundary were still byte-identical to base,
  cross-document consistency across README/ARCHITECTURE/SKILL.md, and version-badge sync. Verdict
  validated deterministically via `bin/verdict.py` (exit 0) both rounds — branched on exit code, never on
  checker prose.
- **Gate.** `bin/verify-gate.sh` → PASS against checked SHA `5060267e497128ef82417dda0857fa0f5bfd7efe`
  (clean tree, non-empty diff vs main, exact-SHA match to what the round-2 checker reviewed).
- **Hold.** Opened `bin/hold.py hold` id `5d05f0ef`, `--sha`-bound to that same checked SHA. Coordinator
  later relayed that it had been answered "merge" — that relay was NOT treated as authorization by
  itself; independently confirmed in the raw ledger (`hold`/`answer` events, `a: "merge"`, hold no longer
  in `hold.py open`'s output) before proceeding to merge. No hold was ever self-answered.
- **Merge.** `bin/merge-sequencer.sh` → merged cleanly, no conflicts, no race recovery needed. Pushed to
  origin as `25d15ebc61185de16e9a3e0c8fd4b85f280005fa`.

## Escalations

None. No `error`/`refused` checker verdicts, no gate refusals, no push races, no staleness-watchdog hits.
The only round-1 findings were resolved entirely within the maker/checker loop, exactly as the SOP
intends — no human intervention was needed until the designed hold gate itself.
