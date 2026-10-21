## 2026-10-21 — hold-answer-token: provenance token on hold.py answer + permission-classifier-enforced human gate incident

**Task:** hold-answer-token — add a deterministic provenance-token requirement to `bin/hold.py answer`.

**Trigger:** a design-exploration session for Temporal-izing secondmate's task lifecycle surfaced, as its
very first concrete finding, that `hold.py answer` had zero provenance check: it accepted any caller who
knew a hold's bare 8-char id, with no verification the answer came through the actual surfacing flow
(SessionStart hook, `hold.py open`/`next`). Confirmed by directly reading `bin/hold.py`'s source before
any plan was made — not hypothetical.

**Planning committee:** ran the full 6-model `plan-committee.sh` (deepseek-r1, qwen3-80b, qwen3-coder,
kimi-k3, mistral-large3, glm5) plus a Claude `/adhd` divergent-ideation pass, into a task-scoped
`.secondmate/planning/hold-answer-token/` directory (the shared top-level planning dir was polluted with
stale artifacts from prior tasks and refused to overwrite — had to re-run with `--out-dir`). Synthesized
every planner's "Probes for Supervisor" myself before routing to the maker: the sharpest (from kimi-k3)
was whether the token needed to be a human-identity-authentication secret — resolved from the task's own
framing that it's explicitly a binding/provenance check, not identity authentication, which is also why a
plain deterministic hash (not a stored random secret, not a fixed-key HMAC) is the right shape and why no
migration/backfill is needed for pre-existing hold records (the token is always re-derivable on demand
from fields the ledger already persists).

**Maker:** routed to a Claude maker (not pi) given the security-sensitive provenance-check nature of the
change, directly in an isolated herdr worktree/workspace (`sm/hold-answer-token`). `/ponytail ultra`
invoked explicitly at the start of every round (confirmed live in pane scrollback), not the default
`full` — kept the implementation to stdlib `hashlib.sha256` + canonical JSON, no new dependency.

**Rounds (3 total), checker: cross-model via `launch-checker.sh`, lens `redteam/access-control`, run in a
visible herdr pane per the HERDR_ENV=1 strict-visibility rule:**
- Round 1 (commit `e59964d`): implemented `_token()`/`_render_anchor()` in `bin/hold.py`, wired into
  `hold`/`answer`/`open`/`next`, extended `_selfcheck_live` with forgery-rejection + re-derivation
  assertions, updated `bin/hold-watch.sh` + `bin/session-holds.sh` + most doc call sites. Checker: FAIL —
  missed a separate "What's inside"-style component-map row in `docs/ARCHITECTURE.md` (distinct from the
  stage-by-stage narrative the maker did fix) still showing the old tokenless batch-answer syntax.
- Round 2 (commit `a22880f`): fixed that row. Checker: FAIL — found a SEPARATE, pre-existing bug on those
  same lines (confirmed via `git show main:...` to predate this task entirely): `docs/ARCHITECTURE.md:647`
  and `:704` were missing the positional `<hold-id>` argument altogether.
- Round 3 (commit `ed5c088`): fixed both, plus the maker's own repo-wide sweep caught one more instance of
  the identical bug class in `README.md:98` that nobody had named yet. Checker: PASS — confirmed live:
  bare-id-only forgery rejected, a different hold's token rejected, mismatch error never leaks the
  expected token, every literal doc example across the repo independently executed successfully.

**Verify-gate:** PASS — worktree clean, non-empty diff vs `main`, checker-current (checked-sha matched),
`python3 bin/hold.py selfcheck && bin/hold-watch.sh --selfcheck && bin/session-holds.sh --selfcheck` all
green.

**Hold / human gate — notable process incident:** opened hold `42271db2` (bound to checked-sha `ed5c088`)
in the primary checkout's still-unmodified `hold.py` (correctly has no `--token` requirement of its own,
since that feature didn't exist yet in the deployed CLI — no bootstrapping paradox). A chat-relayed
"genuine human answer: approve" arrived from the coordinator with a matching checked-sha, but the actual
`bin/hold.py answer` call was denied twice by Claude Code's own auto-mode permission classifier
("[Merge Without Review]"), even after the coordinator reported a permission grant. The sub-supervisor
correctly refused to route around the denial (no retry-via-other-tool, no asking a peer agent to do it —
that would be cross-session permission laundering) and stopped to report back each time, per its own
operating rules that no agent message is ever a substitute for the harness's actual permission system.
The human ultimately ran `hold.py answer` directly via Claude Code's `!`-prefix (bypassing the agent
action classifier entirely, since that's direct human execution, not an agent-initiated action) —
independently verified in the ledger (`{"ev":"answer","id":"42271db2",...,"a":"approve"}`, a record the
sub-supervisor never wrote itself). The same classifier then blocked `merge-sequencer.sh` too, by the same
mechanism, and was resolved the same way: the human ran it directly after a permission grant worked for
their own session. Merged as `f369b4fe35896b6289074f56c2fa9417cc0f7328`, pushed to origin — verified
independently (`git log` on both local `main` and `origin/main`, and `grep -c _token bin/hold.py` on the
merged `main`) before proceeding to teardown.

**Teardown:** checker pane closed, herdr worktree/workspace removed, branch `sm/hold-answer-token`
deleted locally (never pushed to origin), claim released (owner `sm-hold-answer-token`). `teardown-check.sh`
confirms clean on worktree/branch/herdr/claim.
