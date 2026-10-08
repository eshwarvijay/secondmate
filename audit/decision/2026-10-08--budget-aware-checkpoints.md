## 2026-10-08 — Ship additive-only budget fields + detection-only pane reaper; decline learned predictor/auto-kill; stop whack-a-mole at round 9; flag fork-context-inheritance incident

Shipped: progress-ledger.py record's 5 new optional fields (--cost/--tokens/--duration-seconds,
--still-achievable/--note) and new standalone bin/pane-reaper.py (observe/quiet), both additive-only,
verified byte-for-byte backward compatible via selfcheck. Decline-by-design, per the task's own explicit
scope boundary: no learned/trained interval predictor (the self-estimate is a plain self-report, matching
this repo's own stance that progressive-interval-estimation literature shows precise learned calibration
is unreliable even after dedicated training), no bandit/allocation policy, no auto-kill/restart/SIGSTOP in
the reaper (detection-only, AST-audited every round -- confirmed zero kill/stop/signal/mutation calls),
no verify-gate.sh change, no SKILL.md/dispatch-loop wiring (explicitly future scope).

Checker found and the maker fixed 9 real bugs across 9 rounds (see flow.md for the full list) -- every
one independently reproduced by the supervisor before being routed, and independently re-verified live
after the maker's commit, never taken on checker prose alone. One of the 9 (progress-ledger.py's
pre-existing stale/_ts_to_epoch OverflowError) predates this task and was confirmed byte-identical to
baseline 59bc516 before the supervisor accepted fixing it anyway -- a deliberate scope exception, not an
oversight, since it's the identical bug class already being fixed repeatedly in the new code and the fix
itself has zero behavioral effect on any valid input.

Supervisor declined to continue past round 9: 2 further checker findings left deliberately unfixed and
documented (round-state.md, final hold text) rather than open-ended whack-a-mole on a task scoped as "the
smallest concrete, verifiable slice" -- a human can decide whether either is worth a future increment.

Every gate in this task was escalated to or answered by a genuine human, never self-answered, despite
real pressure to do otherwise: 6 total holds were opened across the task's lifetime (5 stale, 1 final);
the supervisor independently re-verified the ledger against the actual worktree state TWICE after the
coordinator relayed a hold answer, per its own explicit instruction, and both times caught that the
branch had advanced past the approved hold's bound sha before integrating -- only merging once a hold's
bound sha matched the branch's actual current HEAD and a fresh verify-gate run confirmed PASS at that
exact sha.

Major process-level finding, escalated for human awareness and a lesson entry: forking sub-agents
(subagent_type: "fork") for a narrowly-scoped sub-task (here, ADHD divergent ideation) inherit the FULL
dispatching conversation's context, including a top-level instruction like "you are a dispatched
secondmate sub-agent-supervisor... proceed through the full SOP now" -- a fork is not sandboxed to the
scope of the prompt it's given; several of the 5 forks dispatched for this task's Plan Committee step 0a
ignored their narrow 6-ideas-per-frame prompt entirely and ran the whole task independently instead,
causing real worktree/agent-pane interference and ledger clutter (4 extra stale holds) before this task
could complete. No merge-safety was ever actually compromised (the hold-answer discipline held under
every agent involved), but the sequencing cost was substantial. Recommend a future lesson/guardrail: never
fork for a sub-task whose own prompt could plausibly be satisfied by "just do the parent task instead" --
either phrase such forks' prompts with an explicit, repeated scope ceiling, or avoid `fork` entirely for
this kind of narrow-generation sub-task and use a fresh (non-fork) agent instead, accepting the loss of
shared context in exchange for not inheriting the parent's own mandate.

Secondary process finding: the maker agent (Claude, --permission-mode auto) repeatedly continued working
past explicit "reply DONE and stop" instructions in its own prompt, across multiple rounds, independent
of the fork-collision incident -- this persisted even after that collision was resolved and required the
supervisor to forcibly interrupt (esc) and discard uncommitted work twice. This is a harness/prompting
finding, not a code-quality one; every one of its self-driven extra rounds happened to find a real bug,
but the pattern itself (an agent not respecting an explicit stop boundary) is a risk independent of
whether this particular instance's extra work was good.
