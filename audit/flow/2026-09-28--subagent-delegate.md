## 2026-09-28 — Allow single-task delegation to a fresh sub-agent-supervisor

**Trigger:** human explicitly reported that secondmate's documented "fan-out to sub-supervisors" pattern
only covered 2 concurrent tasks, and that even that path was unreliable because the SessionStart hook
never mentions it — so an explicit ask to delegate a single task to a sub-agent-supervisor had no
mechanism to invoke.

**Plan committee:** ran unconditionally (deepseek-r1, qwen3-80b, qwen3-coder, kimi-k3, mistral-large3,
glm5) via `plan-committee.sh`. Two runs were wasted to a pre-existing unmarked planning-output directory
and to launching the committee with a trailing `&` that let its parent shell exit and orphan the
background process (killed 5 of 6 planners mid-flight) before a third, correct
`run_in_background: true` invocation completed cleanly. Supervisor synthesis verified the key premise
directly against the repo (grepped `claim-ledger.py`/`hold.py`/`merge-sequencer.sh`): none of them contain
any task-count logic. The "hard cap at 2" lives in exactly one sentence of `SKILL.md` prose, quoted once
in `ARCHITECTURE.md`. This reduced the fix from "generalize three primitives to N>=1" (several planners'
working assumption) to "widen the documented trigger condition, zero executable code changes."

**Maker:** Claude, routed as "complex" (prose-editing across cross-referenced files needs judgment about
wording precision, not pure code) — worktree `sm-subagent-delegate`, single round, no fix loop needed.
Delivered exactly the planned 5-file diff (`SKILL.md`, `session-activate.sh`, `ARCHITECTURE.md`,
`plugin.json` 0.1.32->0.1.33, `README.md`), correctly left `claim-ledger.py`/`hold.py`/`merge-sequencer.sh`
untouched, and proactively grepped for other stale "hard-capped at 2" references.

**Checker:** cross-model (GPT-terra), edit-locked, in a visible herdr pane. First 3 invocations produced
false/misleading results purely from supervisor-side scripting mistakes, not real findings: (1) a quoted
heredoc delimiter (`<< 'SCRIPT_EOF'`) prevented `$wt` from expanding, so `--repo` resolved to an empty
string; (2) the retry used an unquoted heredoc but `${CLAUDE_PLUGIN_ROOT}` was unset in the *generating*
shell at that moment, producing a broken `/bin/launch-checker.sh` path; (3) even with both paths fixed,
`--repo` only feeds `launch-checker.sh`'s internal diff-text computation -- it never `cd`s the checker's
own tool calls into that directory, so the checker's own independent Read/Bash probes still ran against
the primary checkout (main, no diff) while the injected diff text described the real change, producing a
"pass" verdict but with an honest diagnostic caveat flagging the mismatch. Root-caused and fixed by
explicitly `cd`-ing into the worktree as the first line of the checker script before invoking
`launch-checker.sh`. Fourth invocation: genuine pass, no findings, verified directly against the real
diff on disk (`git diff --name-only main..HEAD`, `git diff --check`, JSON/badge parsing for the version
bump).

**Gate:** PASS (clean, non-empty vs main, checker-current SHA).

**Hold:** opened bound to `090b22c8`, answered "yes" by the human with a matching `--sha`.

**Merge:** `merge-sequencer.sh` hit a genuine push race (2 failed push attempts against origin), recovered
automatically within the same lock, landed as `11d06cab` on `main`, pushed successfully.

**Teardown:** clean across worktree, branch, herdr pane, and claim-ledger (no claim was ever taken here --
this task ran through the *existing* single-task loop, not the newly-documented sub-agent-supervisor
delegation pattern itself; the fix was built about that pattern, not with it).
