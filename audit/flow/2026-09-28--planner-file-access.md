## 2026-09-28 — plan-committee: give planners read-only repo tool access

**Trigger:** human flagged a real hallucination caught during the `subagent-delegate` task's plan
committee (deepseek-r1 fabricated a quoted "file excerpt" it never actually read), then explicitly decided
cost/latency of real tool use is not a concern here -- grounding/quality matters more than committee speed.

**Plan committee:** ran unconditionally, 6/6 clean, zero retries. Produced a second, independent, fresh
instance of exactly the failure motivating this task: deepseek-r1 quoted a fabricated implementation of
`bin/committee-output.py`'s `extract()` function that does not match the real code at all (verified by the
supervisor reading the actual function directly) -- caught mid-flight, cited directly in the consolidated
plan rather than treated as a data point. Separately, glm5 produced a degenerate 323-byte response that
cut off mid "let me read the files I need" -- a mild additional signal that a weaker model under a
headless/no-tools constraint can slip into an impossible pretense rather than either verifying or honestly
flagging a probe.

Supervisor pre-verified (by reading the actual code, not assuming) the two structural risks every planner
independently raised as a probe: (1) `committee-output.py`'s `extract()` already only inspects the LAST
assistant message, so multi-turn tool-use transcripts need no code change -- tool-call turns earlier in the
transcript are simply not that message; (2) `run-round.sh`'s idle watchdog tracks raw output-file byte
growth generically (content-agnostic), already compatible with a real tool loop's continuous JSON event
stream, the same mechanism the checker's tool-enabled rounds already rely on today. Both confirmed by
reading the files directly before the maker was ever spawned -- this is the exact discipline (verify
against real files, never trust an unverified claim, planner-sourced or not) that step 0c is meant to
enforce, and it's what caught deepseek's fabrication in the first place.

**Maker:** Claude, routed "complex" (prompt-wording judgment across 6 label functions, not pure mechanical
code) -- worktree `sm-planner-file-access`, single clean round, no supervisor nudges needed this time
(contrast with the prior `fix-checker-cwd` task's two interventions). Delivered a better implementation than
literally instructed: rather than duplicating a reworded notice into all 6 `_prompt_<label>` functions per
the plan's literal wording, it discovered only 2 of 6 (`qwen3-coder`, `kimi-k3`) had explicit "NO tools, NO
file access" hardening text, removed those two, and added ONE shared notice inside `_planner_prompt()` --
the dispatcher every label already routes through -- avoiding 6x text duplication for the same effect. Also
updated the existing `--selfcheck` suite's own assertions consistently (flipped two assertions that
previously *required* the stale no-tools text to now assert its *absence*, added two new assertions for the
new notice and the Probes-reservation wording) rather than leaving them stale or superficially patched.

**Checker:** cross-model (GPT-terra), genuine pass on the first invocation this time -- no supervisor
scripting mistakes this round (unlike the two prior tasks today). Went beyond reading the diff: built its
own fake-`pi` fixture to directly exercise the launch/classify/retry path rather than trusting the diff
summary, and read the full resulting prompt text end-to-end for 2 of the 6 labels (`deepseek-r1`,
`mistral-large3`) per the supervisor's explicit HAMMER instruction not to trust the diff summary alone.
Confirmed zero scope creep: no path deny-list, no new `SM_*` readonly env var, no output-redaction layer, no
`--repo`/`--cwd` flag, `committee-output.py`/`run-round.sh` both untouched.

**Gate:** PASS. **Hold:** answered "yes" by the human, SHA-bound. **Merge:** clean, no push race
(`7d7870ce`).

**Follow-up done directly by the supervisor:** version bump 0.1.34 -> 0.1.35 (plugin.json + README badge),
per the same precedent established in the two prior tasks today -- a real behavioral change to a core
primitive every future task depends on, matching CLAUDE.md's pre-push sync rule and the merge-sequencer's
own printed reminder.
