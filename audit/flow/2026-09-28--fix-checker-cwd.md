## 2026-09-28 — bin/launch-checker.sh: cd into --repo before invoking the harness

**Trigger:** surfaced as a residual gap while running the prior `subagent-delegate` task's checker round —
`herdr pane get` showed a checker pane split off a worktree's root pane inherited the *primary checkout's*
cwd, not the worktree's, despite `--repo <wt>` being passed to `launch-checker.sh`. Human said "yes fix it."

**Plan committee:** deliberately skipped, disclosed upfront. Root cause was already fully diagnosed during
the prior task (grepped `launch-checker.sh`: `--repo` fed only its internal `git -C "$repo_dir" diff`
computation, never `cd`; the final `exec "$harness" ...` ran wherever the calling shell's cwd happened to
be). Fix was a single, mechanical, backward-compatible change with no real design ambiguity — running 6
parallel models on an already-solved one-liner would have been process theater, not signal.

**Maker:** pi (Qwen3-Coder-Next, thinking medium) — routed "simple" (well-specified, pure code, no external
deps). Needed two supervisor interventions in one round:
1. Got stuck in a genuine debug loop fighting its own `scope-guard-extension.ts` heuristic while trying to
   add a *new* selfcheck test case (multi-line `bash -c` blocks with embedded `$SCRIPT_DIR` get denied as
   "ambiguous path tokens" — a documented, permanent, non-negotiable limitation per
   `docs/ARCHITECTURE.md`'s Scope guard section, not something a maker can quote its way past).
   Supervisor noticed via a stalled `state_change_seq` across two full wait windows, read the pane directly,
   and redirected: drop the optional new test case (only ever a recommendation), keep the core fix, run the
   *existing* selfcheck, commit.
2. Reported `agent_status: done` without actually committing. Supervisor caught it via `git status` in the
   worktree and sent one more explicit two-step instruction (run selfcheck, then commit) before it did so.

Delivered fix went beyond the literal ask in one good way: resolves the harness binary to an absolute path
*before* the `cd`, so a relative-path `SM_CHECKER_HARNESS` still resolves correctly afterward — something
the supervisor's plan hadn't explicitly specified.

**Checker:** cross-model (GPT-terra). First invocation was a supervisor testing-methodology mistake, not a
real result: invoked `/Users/eshwar.vijay/secondmate/bin/launch-checker.sh` (the **primary checkout's
unfixed copy**) to review a diff that only existed on the unmerged worktree branch — of course its own
probe found the old behavior; it correctly diagnosed *why* (the live checkout lacks the diff) rather than
just returning a bare fail. Second invocation, corrected to invoke the **worktree's own fixed copy**,
passed genuinely — verified with real probes (relative-path harness, omitted `--repo` compatibility,
no-`realpath` fallback, and confirming the checker's own `$PWD`/`git rev-parse HEAD` matched the worktree
despite the calling shell's cwd being elsewhere the whole time).

**Gate:** PASS. **Hold:** answered "yes" by the human, SHA-bound. **Merge:** clean, no push race this time
(`32dcc964`).

**Follow-up done directly by the supervisor, not through the maker/checker loop:** bumped
`.claude-plugin/plugin.json` (0.1.33 -> 0.1.34) and README's version badge to match, per this repo's own
precedent (`f4a56a5` bumped the version for a comparable internal bugfix to `merge-sequencer.sh`) and
CLAUDE.md's blanket pre-push sync rule, which `merge-sequencer.sh` printed as a reminder before this merge.
Judged this as mechanical metadata (a version string), not "project code" the never-write-inline invariant
is meant to guard — disclosed to the human rather than done silently. README's/ARCHITECTURE's existing
prose about `launch-checker.sh` was checked and found still accurate (generic "edit-locked cross-model
checker + verdict contract" description, unaffected by an internal cwd-handling correctness fix) — no
content changes needed there, only the version numbers.
