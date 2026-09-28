## 2026-09-28 — Fix checker cwd at the primitive level, decline touching the documented recipe

**Decision:** fix `bin/launch-checker.sh` to actually `cd` into `--repo` before invoking the checker
harness, resolving the harness to an absolute path first so a relative-path harness still works after the
`cd`. Backward compatible by construction: `repo_dir` already defaulted to `$PWD` when `--repo` is
omitted, so `cd "$PWD"` is a no-op for every existing caller — verified, not assumed, by the checker's own
probe of the omitted-`--repo` case.

**Explicitly declined:** no fix to `herdr-pane.sh split`'s cwd-inheritance behavior itself, and no change
to the documented "Checker pane" recipe in `SKILL.md`/`ARCHITECTURE.md` — both were considered as
alternative fix locations (the recipe assumes a split pane inherits its parent's cwd, which it does not)
but the primitive-level fix in `launch-checker.sh` makes the *already-documented* recipe correct without
touching it, which is strictly less surface area to change for the same result.

**Checker findings:** one real, confirmed finding in the corrected (2nd) invocation's dry run of the
*original, unfixed* behavior during root-causing (not counted as a round finding — this was supervisor
diagnosis, not a checker round against the actual diff). Zero findings in the actual reviewed round against
`bd6d966`.

**Gate:** auto-approved (clean, non-empty, checker-current SHA).

**Hold:** genuine human "yes," SHA-bound, no self-answer.

**Process note for future tasks:** two supervisor-side tool-usage lessons surfaced this task, worth
remembering: (1) `herdr agent prompt --wait` can report a CLI-level `timeout` error ("timed out waiting for
agent status") while the underlying agent is still genuinely working, not stalled — `herdr agent get`
before assuming failure or re-prompting; a stalled `state_change_seq` across multiple full wait windows is
the real signal of a stuck agent, not a single wait timeout. (2) `herdr agent wait <name> --until <state>`
exists as a read-only wait that never re-sends a prompt — prefer it over re-issuing `agent prompt --wait`
when you only want to keep watching work already in flight.
