## 2026-10-21 — temporal-herdr-visible-flag: 2 legit checker findings fixed, 1 pre-existing out-of-scope; human-approved merge; live-demo proof

## Decision — temporal-herdr-visible-flag

**What the maker decided.** Added `--herdr-task-id ID` as a new CLI flag on `cmd_round` (not an env
var — same reasoning the script already applies to `--i-accept-headless-autonomous-risk`), validated
locally against the bridge's own `sanitizeTaskID` charset/length rule
(`^[a-z0-9][a-z0-9_-]{0,19}$`, read directly from `internal/planrun/herdr.go`, not trusted from
paraphrase) before `_build_plan_json` or any subprocess runs. Threaded into both `step-maker`/
`step-checker` `params.herdr_task_id` only when non-empty (byte-identical plan JSON otherwise). Added
as a THIRD branch on the `HERDR_ENV=1` guard: supplying `--herdr-task-id` now lets a round proceed
without `--i-accept-headless-autonomous-risk`, since the bridge's now-merged
`bridge-herdr-visible-activities` feature gives that round a real interactive pane, closing the two
gaps the guard exists for; the existing headless-override branch and the neither-flag-given refusal
are unchanged. Docs synced per CLAUDE.md's doc-sync rule (SKILL.md, README.md, ARCHITECTURE.md,
plugin.json 0.1.46→0.1.47). Invoked `ponytail` before writing code per the human's explicit
instruction; kept the diff to one flag + one validation check + one threaded arg + one guard-condition
edit, no new helper functions, no new config knobs. Also discovered and documented (not fixed, out of
scope) that the bridge's herdr-visible maker ignores `--repo` and resolves/creates its own
`herdr-task-<ID>` worktree — named as a caller/dispatcher contract in the script header, SKILL.md, and
ARCHITECTURE.md rather than silently left implicit.

**What the checker found, round by round.**
- Round 1 (redteam/injection lens, visible pane, diff-base `18f9def`): **fail**, 3 CONFIRMED findings.
  Two were real: (1) an explicitly-empty `--herdr-task-id ''` silently bypassed validation instead of
  failing (couldn't distinguish "flag never given" from "flag given empty", both left the variable
  `""`); (2) the neither-flag-given `HERDR_ENV=1` refusal message text had drifted from the base
  script (an appended clause advertising the new flag), violating the "refuse exactly as it does
  today" invariant for the absent-flag path. The third (a PATH-hijacked `dirname` call executing
  before `--herdr-task-id` validation on a malicious value) was verified by the supervisor via
  `git show 18f9def:bin/run-round-temporal.sh` to be byte-identical in the base script — module-scope
  bootstrap code that runs before `cmd_round` even exists, for every invocation regardless of any
  flag. Pre-existing, not a regression this task introduced; explicitly told to the maker as
  DO-NOT-FIX and to round 2's checker as not-a-blocker (with the reasoning spelled out so the checker
  wouldn't need to re-derive it).
- Round 2 (same lens, diff-base `5a07302`, prior verdict auto-injected): **pass**, zero findings. The
  checker independently re-verified both fixes (including repeated-flag last-value-wins behavior and
  a literal `a$(touch ...)` injection payload rejected before `python3`/`git`/`cat` ran), confirmed the
  no-flag dry-run plan JSON byte-identical to the pre-maker base, confirmed both HERDR_ENV=1 branches
  byte-identical to base where required, and explicitly named (without re-flagging as a new defect)
  the same pre-existing bootstrap-dirname observation, exactly as instructed.

**Every gate, auto-approved or escalated, and why.**
- `--selfcheck` — auto-approved both rounds; the supervisor independently re-ran it itself (not just
  trusting maker/checker self-reports) and got `ok` both times.
- `verify-gate.sh` — auto-approved: PASS (clean, non-empty vs `main`, checker-current at the exact
  checked sha, tests green).
- Human hold `1d8023f4` — escalated, never self-answered. The supervisor's own hold question included
  the full 2-round rationale, the bridge dependency it now uses, and the pre-existing-finding
  adjudication, plus the maker's `--repo`/`--herdr-task-id` worktree-matching caveat. The human
  answered a plain "yes" (merge approval), explicitly distinguished from the "file a follow-up for the
  dirname issue" option, which the human did not ask for.
- Merge — `merge-sequencer.sh` landed `sm/temporal-herdr-visible-flag` onto `main` as `e8f6872`, pushed
  to origin. Teardown confirmed clean (`teardown-check.sh`: worktree/branch/herdr/claim all clean).

**Post-merge live verification (human-requested, not part of the standard SOP).** Ran a genuine live
round via the real local Temporal bridge under `HERDR_ENV=1` with `--herdr-task-id smlivedemo1`
against a disposable worktree/branch (`herdr-task-smlivedemo1`, torn down afterward, never merged): a
real herdr-tracked `claude` agent `mk-smlivedemo1` came up on a real pane (`w82:p1`), a real checker
ran on a real split pane (`w82:p2`), both completed with real, observed status (`step-maker:
status=ok`, `step-checker: status=ok`, checker verdict `pass`), and the wrapper committed the real
diff as `884dddbbd40adecfe4c726a3bd96258e18bb80db` with real `Temporal-Workflow-Id`/`Temporal-Run-Id`
trailers. This is independent, live proof beyond `--selfcheck`/dry-run/injection-probe evidence that
the shipped flag genuinely routes a round through the bridge's herdr-visible mode end to end.
