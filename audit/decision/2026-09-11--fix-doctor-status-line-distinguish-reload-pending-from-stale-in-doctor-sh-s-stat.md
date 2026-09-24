## 2026-09-11 — fix-doctor-status-line: distinguish reload_pending from stale in doctor.sh's STATUS line (fan-out live validation)

- **Maker (pi/Qwen3-Coder-Next, medium thinking):** added a `reload_pending_count` counter distinct from
  `stale_count` (reset in `_reset_detect_state()`), a new `RELOAD_PENDING` branch in `add()`, switched
  `_detect_secondmate_staleness()`'s `reload_pending` case to use it (leaving `stale`/`silent_drift` sharing
  `stale_count`, unchanged, out of scope), and inserted one new `elif` in `emit_table()`'s STATUS-line
  precedence chain between the existing `stale_count` branch and the final `else`. Added selfcheck Test O.
  One round, no correction needed.
- **Decisions:** (1) deliberately left `silent_drift`'s STATUS message sharing `stale_count`'s "needs
  healing" text — named explicitly in the task as out of scope, a separate already-known, already-documented
  quirk from an earlier task's own decision.md entry, not this task's to fix; (2) confirmed via direct
  grep of every consumer in this repo that `emit_json()`'s raw `status` tag changing from `STALE` to
  `RELOAD_PENDING` for the reload_pending row (a real, disclosed side effect the checker itself flagged as a
  SPEC AMBIGUITY, not a finding) has zero blast radius — the only consumer (`commands/secondmate-doctor.md`)
  filters exclusively on `"status":"MISSING"`, and no selfcheck test asserts on that field's exact string for
  this row; (3) declined to make any README.md/docs/ARCHITECTURE.md edit — confirmed no table or diagram
  describes the STATUS-line summary text verbatim, so nothing there goes stale from a message-text-only fix.
- **Checker findings resolved:** none — clean `pass`, zero findings, after 1 real round (run twice due to an
  infrastructure gap unrelated to the maker's code — see below — with the second, clean-cwd run treated as
  the trusted result). One SPEC AMBIGUITY raised (the `emit_json` status-tag change) — investigated and
  confirmed harmless, not escalated, not fixed (nothing to fix; it's correct, intended behavior per the
  task's own spec, which never promised JSON-status byte-identity, only table-row byte-identity).
- **Supervisor verification discipline:** independently read the full diff; ran the real `bin/doctor.sh
  --selfcheck` directly in the worktree (clean); personally mutation-tested Test O (reverted the
  `emit_table()` fix, confirmed Test O then failed with the predicted symptom, restored, reconfirmed clean)
  before ever trusting the maker's own "mutation-tested" claim in its DONE summary; re-ran the full selfcheck
  a second time against the actual **merged** commit on main (not just the pre-merge worktree) before
  considering the task done, matching this repo's own standing "verify the merged result, not just the
  branch" discipline.
- **Infrastructure findings (both real, both fixed, neither a doctor.sh bug — full detail in flow.md):**
  (1) `herdr-pane.sh split --pane <id> --dir down` does not make the new pane inherit the source pane's cwd,
  and `launch-checker.sh --repo` only scopes the diff text, not the checker process's own cwd — the first
  checker round silently ran against the primary checkout instead of the worktree until the checker itself
  caught and disclosed the mismatch; re-run with an explicit `cd` fixed it for this task, structural fix
  deferred; (2) `bin/merge-sequencer.sh` correctly refused to merge into a dirty primary checkout — two
  untracked, never-gitignored append-only artifacts (`audit/merge-ledger.jsonl`, `audit/metrics.jsonl`) from
  this repo's own tooling. Fixed by adding both to `.gitignore` (commit `49418bd`, verified no concurrent
  merge-sequencer lock was held before touching the primary checkout), matching this repo's own first-ever
  precedent for the identical class of problem (`.secondmate/` blocking `verify-gate.sh`).
- **Fan-out pattern validation:** claimed first via `claim-ledger.py` (token minted, released on the
  terminal path, never before); derived every name deterministically from the task-id; ran the untouched solo
  SOP; opened its own hold (`b42c2ebb`) and **genuinely stopped and reported `SM_STUCK_NEED_HUMAN`** rather
  than assuming an answer, when the hold was still open. On resumption, independently re-verified the answer
  via both `bin/hold.py open` (empty) and the raw `decisions.jsonl` record (`"a":"merge"`) before proceeding
  to merge — never took the resuming message's claim at face value, exactly as instructed.
- **Gates:** verify-gate PASS at `eb7926f` (checked-sha match) → hold `b42c2ebb` answered `merge` (genuine,
  independently re-verified) → merged to main via `bin/merge-sequencer.sh` at `664b1c8`, pushed → full
  repo-wide selfcheck re-run clean on the actual merged commit → worktree/branch/pane torn down → claim
  released.
- **Escalations:** none — the hold-wait-resume cycle was exercised for real (a genuine STUCK-then-resume, not
  a self-answered hold), and both infrastructure gaps were fixed directly by the sub-supervisor as narrow,
  low-risk, precedented hygiene fixes rather than escalated, given no active lock/race was found at the time
  of the `.gitignore` fix and the checker-cwd issue self-corrected transparently before any code trust
  decision was made on top of it.
