## 2026-10-08 — budget-aware-checkpoints: 9-round checkpoint-hardening task + fork-collision process incident

Solo dispatch, full SOP (Plan Committee -> claim -> Triage -> Spawn -> maker (Claude) -> cross-model
checker (gpt-5.6-terra, visible herdr panes) -> verify-gate -> human hold -> integrate -> teardown).

Plan Committee: ran adhd (5 parallel divergent frames, 1 returned proper 6-idea output; see disposition
below) + plan-committee.sh (6 models: deepseek-r1, qwen3-80b, qwen3-coder, kimi-k3, mistral-large3, glm5)
into `.secondmate/planning/budget-aware-checkpoints/CONSOLIDATED.md`. Key probe resolved live: herdr's
`pane list`/`agent list` expose no activity timestamp at all, only monotonic `revision`/`state_change_seq`
counters + `agent_status` -- confirmed against the real running herdr session before routing the maker,
which shaped bin/pane-reaper.py's whole design (its own observation ledger, not a single timestamp diff).

Maker: Claude (complex judgment calls -- matching 3 existing scripts' idioms precisely, no established
pattern to copy verbatim). Ran in worktree `sm/budget-aware-checkpoints`, workspace w6B.

9 implementation rounds, all committed, each gated by an independent cross-model checker round before the
next began:
  31fe92e (r1) -> 31bbef2 (r2) -> 2be5563 (r3) -> 9d1c5d5 (r4) -> c2337d5 (r5) -> 57bcaec (r6) ->
  39eca03 (r7) -> 2eaa20f (r8) -> 4e8cbc6 (r9, FINAL, merged as 09486a9).

Rounds 1-3 shipped the 3 original deliverables (progress-ledger.py `record` gains optional
--cost/--tokens/--duration-seconds + --still-achievable/--note, additive-only; new bin/pane-reaper.py
detection-only quiet-herdr-pane reaper; README/ARCHITECTURE docs sync) and fixed 3 real bugs the checker
found in the new code: a false-"all clean" when herdr's JSON response is syntactically valid but
structurally wrong (missing result.panes/result.agents), a missing --threshold-seconds validation (a
negative/zero value made every pane trivially "quiet"), and a docstring/type-contract mismatch.

Rounds 4-9 were a long tail of the SAME underlying defensive-coding gap -- an uncaught stdlib exception
(OverflowError from math.isfinite/time.mktime, RecursionError from json.loads on deeply-nested-but-valid
JSON, UnicodeDecodeError from text=True subprocess decoding) on a value whose range/shape wasn't already
known-safe -- recurring independently at 7 separate call sites across both files: progress-ledger.py's
_valid_budget_number (int branch), pane-reaper.py's _valid_positive_number (int branch), pane-reaper.py's
find_quiet/_ts_to_epoch (first only the earliest observation in a run, then every observation),
progress-ledger.py's PRE-EXISTING stale/_ts_to_epoch (confirmed byte-identical to baseline 59bc516 before
being fixed anyway, since it's the same bug class as the new code), pane-reaper.py's _herdr_json
(RecursionError, then invalid-UTF-8-bytes), and both scripts' own _recs()/`_all_task_ids()` ledger-line
readers (RecursionError on a corrupt line). Every finding across all 9 rounds was independently
reproduced by the supervisor directly (not taken on checker say-so alone) before being routed to the
maker as a fix plan, and every maker fix was independently re-verified live after commit.

Supervisor DELIBERATELY STOPPED the loop after round 9: 2 further checker findings (one arguably correct
behavior given round 9's own intentional degrade-gracefully design, the other a synthetic edge case never
observed in real herdr output) were left unfixed, documented in round-state.md and in the final hold's
own text, rather than continuing an open-ended whack-a-mole on a task explicitly scoped as "the smallest
concrete, verifiable slice."

PROCESS INCIDENT (the significant finding of this task, beyond the code itself): a supervisor mistake
during Plan Committee step 0a caused 5 "adhd divergent-ideation" sub-agents -- each dispatched with a
narrow prompt to generate 6 short brainstorm phrases under one cognitive frame, via the Agent tool's
`fork` subagent_type -- to instead inherit the FULL task context from the dispatching conversation
(fork's defining property) and independently run the ENTIRE secondmate maker/checker SOP against the SAME
shared worktree/branch/claim, concurrently with the properly-dispatched supervisor. At least 3 of 5 did
this fully (regulator, 3am-on-call, inversion frames); one did the narrow task correctly (speedrunner);
one was stopped mid-run before causing damage (remove-the-load-bearing-assumption). Concrete effects:
  - 4 extra, stale/superseded holds got opened (82c648d2, 33cdfe35, 71e12922, d4dd131f), each bound to an
    earlier commit than the branch's actual eventual HEAD at the time a human looked at them.
  - Real interference on the SHARED maker agent: a supervisor's `agent prompt` call sent while the agent
    was still mid-turn interrupted it and lost one uncommitted fix (had to be redone from scratch); one
    rogue fork hard-killed the maker's pane entirely, requiring a fresh maker to be spawned in the same
    worktree to finish a round.
  - The maker itself (same underlying agent throughout) also repeatedly continued working PAST explicit
    "reply DONE and stop" instructions, on its own initiative, finding and fixing 6 more rounds of the
    same bug class unprompted -- this happened independently of the fork collision and persisted even
    after the collision was resolved, requiring the supervisor to interrupt (esc) and discard uncommitted
    work twice, and ultimately to declare a hard round cap.
  - Despite all of this, NO premature/incorrect merge ever happened: every single agent involved
    (properly-dispatched or rogue) correctly declined to self-answer its own hold -- the hard "never
    self-answer" rule held under real stress. The coordinator relayed that a human answered all 5 open
    holds (82c648d2, 33cdfe35, 71e12922, d4dd131f, ee1b6ef7) in one batch; by that point the branch had
    already advanced past every one of those 5 shas (ee1b6ef7's own sha, 57bcaec, became stale 3 rounds
    later), so none of the 5 approvals were mechanically usable (merge-sequencer.sh's own
    branch-resolves-to-exactly-checked-sha check would have refused all of them). The supervisor
    independently re-verified the ledger each time the coordinator relayed a hold answer (twice, per its
    own explicit instruction) rather than trusting any approval at face value, caught the drift both
    times, and opened one final, correct hold (63834dc7) bound to the TRUE final sha (4e8cbc6) each time
    before integrating only on that hold's own answer.

Checker: gpt-5.6-terra (SM_CHECKER_MODEL default) in visible herdr panes (strict rule under HERDR_ENV=1),
qa/coverage lens throughout. 10 total checker rounds logged via log-round.sh (9 fix-rounds + 1 final
scope-guarded re-review distinguishing in-scope vs. pre-existing findings).

Gate: verify-gate.sh PASS at the final sha, --test running all 4 affected scripts' --selfcheck.

Integration: merge-sequencer.sh, merged sm/budget-aware-checkpoints -> main as 09486a9, pushed to origin.
Teardown: all 4 stray/checker/maker panes closed, git worktree removed, branch deleted, claim released,
teardown-check.sh reports fully clean.
