## 2026-09-11 — fix-scope-guard-marker-doc: resolve the /scope-guard-marker doc/registration mismatch (fan-out live validation, sibling of fix-doctor-status-line)

- **Trigger:** the same live, real end-to-end fan-out validation as `fix-doctor-status-line` above — this
  sub-supervisor was the second of exactly 2 concurrent tasks dispatched from one top-level Agent-tool call.
  The task itself was a real, previously-deferred issue from the `pi-scope-guard` task's own accepted-limitation
  note: `docs/SCOPE-GUARD-PI.md` documented a `/scope-guard-marker` pi extension command that
  `bin/scope-guard-extension.ts` never registered.
- **Maker path:** pi (Qwen3-Coder-Next, medium thinking), dedicated worktree workspace `w2B`, root pane
  `w2B:p1`.
- **Worktree:** `herdr worktree create` → `sm/fix-scope-guard-marker-doc`.
- **Planner committee:** ran unconditionally (6 pi planners). `/adhd` skipped — investigation (reading the
  actual `scope-guard-status` handler and grepping the repo) resolved the Option A/B design call before the
  committee even ran: `/scope-guard-status` already prints "Marker path: <path>", so a dedicated
  `/scope-guard-marker` command would be pure duplication (Option B: remove the dead doc section). One
  planner (qwen3-80b) recommended a shared `bin/utils/` utility function citing prior art (`verify-worktree.ts`,
  `clean.ts`) that does not exist anywhere in this repo — discarded as hallucinated noise, confirmed via direct
  `ls`/`grep`. A security-surface planner (mistral-large3) raised an OS-command-injection concern tied to a
  nonexistent "Pi Worktree.path API" — discarded as inapplicable (no code path touched by the chosen doc-removal
  direction; the existing `is_maker_worktree` already uses `execFileSync`'s argv-array form, not shell
  interpolation). Every other probe (other pi extensions with a status+marker pairing convention; existing
  doc/registration selfcheck; scripts depending on `/scope-guard-marker`) was answered directly from the repo —
  none existed.
- **Rounds:** 4 real checker rounds (`global.openai.gpt-5.6-terra`, `qa/coverage` + `qa/test-reality` lenses),
  each finding a genuine, independently-reproduced bug in the maker's new doc/registration consistency check
  (`bin/scope-guard-selfcheck.sh`) before ever advancing:
  1. A syntactically broken `sed` (BSD sed rejects an unescaped extra `/` delimiter) silently swallowed by a
     trailing `|| true`, guaranteeing a false-positive FAIL on ANY doc state, correct or not — plus the check
     was appended after tests that already fail under `set -e` due to an unrelated, pre-existing, out-of-scope
     hardcoded stale-worktree-path bug, making it dead code that would never actually run. Fixed by correcting
     the sed delimiter and moving the check to run first.
  2. The registration-extraction regex only matched a single-line, double-quoted `pi.registerCommand("name", {`
     call — a routine multiline reformat, OR a second registered command, both silently produced a false PASS
     (the second case because the extraction returned only the first match without a `/g` flag). Fixed with a
     `tr`-flatten + `perl -ne '... while /pattern/g'` approach.
  3. Single-quoted and template-literal (backtick) registrations were still invisible (quote character hardcoded
     to `"` only) — another silent false PASS. The maker got stuck in a genuine shell-quoting debugging loop
     (compounded by `scope-guard-extension.ts`'s own Bash path-heuristic repeatedly false-positiving on inline
     commands containing backticks/quotes as "ambiguous path token") without converging; the supervisor
     independently derived, verified (on a real 4-case fixture plus the actual file), and handed over an exact
     verbatim working perl regex (capturing the quote character itself and backreferencing it to find the
     matching close, printing the correct capture group) — matching this repo's established "give exact
     verbatim code after a stuck-loop recurrence" precedent (`doctor-version-flag`, `doctor-plugin-update`).
  4. A remaining edge case (a command name containing an embedded quote character of a different type than its
     own delimiter) was independently reproduced as real, but judged by the supervisor as an unrealistic trigger
     for this codebase's plain-kebab-case slash-command naming convention, and the same fundamental class of
     limitation as the already-accepted comments/dead-code gap (text matching, not a real parser) — folded into
     the SAME existing limitation comment rather than chased with more regex changes, explicitly citing this
     repo's own `scope-guard-hook` precedent for stopping an unbounded text-heuristic patch series. Checker
     round 4 independently endorsed this framing and returned a clean pass.
- **Supervisor verification discipline:** every one of the 4 findings above was independently reproduced by the
  supervisor (real mutation fixtures — multiline reformat, second registration, single-quote, template-literal,
  embedded-quote — each added to a scratch copy of `bin/scope-guard-extension.ts`, confirmed, then reverted)
  BEFORE being routed to the maker or accepted as a checker claim, and every fix was independently re-verified
  by the supervisor with the same fixtures afterward, never trusted from the maker's or checker's own report
  alone.
- **Fan-out pattern itself — worked as documented, including two things the sibling task didn't exercise:**
  (1) `bin/plan-committee.sh`'s default out-dir collision guard correctly refused against unrelated, pre-existing
  stale debris in `.secondmate/planning/` (leftover from an old task, not the concurrent sibling) — resolved
  with a task-scoped `--out-dir`, the guard working exactly as designed, not a bug; (2) claimed via
  `claim-ledger.py` first, opened its own hold (`fb24ff72`) bound to the checked-sha and genuinely stopped
  emitting `SM_STUCK_NEED_HUMAN`, independently re-verified the "resume" message against both `bin/hold.py open`
  (no open decisions) and the raw `decisions.jsonl` record (`{"ev":"answer","id":"fb24ff72",...,"a":"merge"}`)
  before proceeding, exactly matching the sibling's own hold-wait-resume discipline; (3) `bin/merge-sequencer.sh`
  ran cleanly on the first attempt against a `main` that had already moved forward twice (the sibling's own
  merge + its audit-log commit) since this worktree's base — the sibling's own mid-task `.gitignore` fix
  (`49418bd`, same day) meant this task never hit the dirty-repo guard gap the sibling discovered.
- **Outcome:** verify-gate PASS at `b5400d6` (checked-sha match) → hold `fb24ff72` answered `merge` (genuine,
  independently re-verified from the raw ledger before acting) → merged to main via `bin/merge-sequencer.sh`
  at `e2de42f`, pushed → real selfcheck (`bin/scope-guard-selfcheck.sh`'s new consistency block) re-run clean
  on the actual merged commit → worktree (`w2B`)/branch/panes torn down → claim released.
- **Lesson:** the single biggest time/cost sink this task hit was a maker stuck in a genuine shell-quoting
  spiral trying to derive a multi-quote-style perl regex interactively, made worse by the extension's own
  Bash-heuristic false-positiving on the exact debugging commands needed to test it — recovered the same way
  this repo has recovered from stuck loops before (hand over an exact, pre-verified line, not another abstract
  instruction), not by patching the false-positive heuristic itself (out of scope). Also: a plain "this is a
  small doc-fix task" self-assessment at the start would have badly undersold how many real, distinct bugs
  the maker's own new selfcheck coverage would go through before a checker actually endorsed it — this doc-only
  task ended up needing exactly as much independent-reproduction rigor as this repo's larger code-change tasks.
