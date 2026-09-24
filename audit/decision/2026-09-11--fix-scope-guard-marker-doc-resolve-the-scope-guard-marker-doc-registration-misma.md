## 2026-09-11 — fix-scope-guard-marker-doc: resolve the /scope-guard-marker doc/registration mismatch (fan-out live validation, sibling of fix-doctor-status-line)

- **Maker (pi/Qwen3-Coder-Next, medium thinking):** removed the dead `/scope-guard-marker` section from
  `docs/SCOPE-GUARD-PI.md` (Option B) and built a generalized, text-based symmetric doc/registration
  consistency check into `bin/scope-guard-selfcheck.sh`, running before any real `pi`-spawning tests.
- **Design decision (supervisor's own call, before the committee ran):** chose Option B over Option A
  (registering a real `/scope-guard-marker` command) after reading `scope-guard-status`'s actual handler —
  it already prints "Marker path: <path>", so a dedicated command would be pure duplication — and confirming
  via repo-wide grep that nothing except the doc itself and a historical `audit/decision.md` log entry
  (correctly left untouched) referenced `/scope-guard-marker`. `/adhd` was skipped on the same basis: the
  option A/B question was closed by direct investigation, not genuinely open-ended once inspected.
- **Checker findings resolved, most severe first (all real, all independently reproduced by the supervisor
  before being routed to the maker or accepted as a checker claim):**
  1. A broken `sed` delimiter (BSD sed) swallowed by `|| true`, producing a guaranteed false-positive FAIL on
     any doc state, PLUS the check's placement after `set -e`-fatal, unrelated pre-existing test failures made
     it dead code that would never execute in a real run — both fixed (correct sed, check moved to run first).
  2. Registration extraction only matched single-line, double-quoted calls — a silent false PASS on a routine
     multiline reformat, and (more severely) on a genuinely undocumented SECOND registered command, since the
     extraction returned only the first match with no `/g` flag — fixed with a `tr`-flatten + `perl -ne
     '... while /pattern/g'` approach, the supervisor's own from-scratch multi-registration mutation confirming
     the fix.
  3. Single-quote and template-literal registrations were still invisible — fixed after the supervisor
     interrupted a genuine maker stuck-loop (shell-quoting spiral, compounded by the pi extension's own Bash
     path-heuristic false-positiving on the exact debugging commands needed) and handed over an exact,
     independently-verified verbatim perl regex rather than another abstract instruction.
  4. A remaining edge case (a command name with an embedded quote character of a different type than its own
     delimiter) was confirmed real but ruled an unrealistic trigger for this codebase's plain-kebab-case
     command-naming convention and the same fundamental class of limitation already accepted for comments/dead
     code (text matching, not a real parser) — folded into the existing limitation comment rather than chased
     with more regex changes, explicitly citing this repo's own `scope-guard-hook` precedent for stopping an
     unbounded text-heuristic patch series. The checker's own round-4 pass independently endorsed this framing
     rather than re-raising it as a blocking finding.
- **Fan-out pattern validation:** claimed first via `claim-ledger.py` (token minted, released on the terminal
  path); derived every name deterministically from the task-id; ran the untouched solo SOP (6-model plan
  committee, `/adhd` deliberately skipped with reasoning recorded above, 4 real checker rounds); opened its
  own hold (`fb24ff72`) and **genuinely stopped and reported `SM_STUCK_NEED_HUMAN`** rather than assuming an
  answer, when the hold was still open. On resumption, independently re-verified the answer via both
  `bin/hold.py open` (empty) and the raw `decisions.jsonl` record (`"a":"merge"`) before proceeding to merge —
  never took the resuming message's claim at face value. `bin/merge-sequencer.sh` succeeded on the first
  attempt against a `main` that had already advanced twice (the concurrent sibling's own merge + audit commit)
  since this worktree's base, confirming the pattern's core promise (independent, non-conflicting diffs merge
  cleanly against a moving `main` without any special-casing).
- **Gates:** verify-gate PASS at `b5400d6` (checked-sha match) → hold `fb24ff72` answered `merge` (genuine,
  independently re-verified) → merged to main via `bin/merge-sequencer.sh` at `e2de42f`, pushed → real
  selfcheck (the new consistency block, not a broader chain) re-run clean on the actual merged commit →
  worktree/branch/panes torn down → claim released.
- **Escalations:** none — the hold-wait-resume cycle was exercised for real (a genuine STUCK-then-resume);
  the Option A/B design call and the round-4 accepted-limitation call were both the supervisor's own
  judgment, made without an available `AskUserQuestion` channel in this sub-supervisor context (the only
  human-interaction primitive available was `bin/hold.py`, reserved for the merge decision per the fan-out
  pattern's own contract) and consistent with this repo's existing precedent for when a supervisor may decide
  a scope/limitation question itself versus escalate it.
