## 2026-10-21 — temporal-wrapper-prompt-parity: two real path/symlink-confinement bugs caught+fixed across 3 rounds; merge hold answered by human

## Decision — temporal-wrapper-prompt-parity

**What the maker decided:** mirror `launch-checker.sh`'s own `--lens` CLI shape exactly (repeatable/
comma-separated `--lens NAME`, resolving `bin/lenses/<NAME>.md`) rather than inventing a different
shape; route lens content + a `lens_coverage`-reporting instruction into `checker_goal_full` only
(never the maker prompt, never the bare `checker_goal` used in the commit message), since direct
read-only inspection of the bridge's `checker.go` confirmed `params.goal` is the ONLY per-round text
channel into the checker's prompt — the base discipline (`checker-prompt.md`) and the verdict
envelope (`checker-envelope.md`) were already wired in, unchanged, via
`BRIDGE_CHECKER_PROMPT`/`BRIDGE_CHECKER_ENVELOPE` env vars. Pulled the maker-prompt-closing-boilerplate
text verbatim from SKILL.md rather than paraphrasing, and converted its two `$(...)` command-substitution
lines (handoff/feature-list injection) into real bash `if`/`cat` logic, since a single-quoted heredoc
can't expand `$(...)` — the checker independently verified this conversion is byte-for-byte equal in
content, differing only in mechanism. Added an optional `--task-id` flag (mirroring the `--herdr-task-id`
convention) threading through to `lesson-lookup.py`'s own optional `--task-id`, omitted entirely (not
passed empty) when absent.

**What the checker found (3 rounds, redteam/injection lens, cross-model GPT, always a visible herdr
pane per the `HERDR_ENV=1` strict-visibility rule):**
- Round 1 FAIL: two CONFIRMED real defects — (a) `--lens` path traversal, a bare `[ -f ]` check with
  no root-confinement let `../../../tmp/evil` read an arbitrary file and inject its content into the
  checker's prompt; (b) a `round-state.md` lacking a trailing newline glued directly into the
  following lesson output with no separator, since the real-bash conversion of SKILL.md's
  `echo`-then-`cat` template dropped the implicit newline `echo` always supplied.
- Round 2 FAIL: the round-1 containment fix (`cd $(dirname ...) && pwd -P`) resolved only the lens
  file's PARENT directory — structurally unable to resolve a symlink on the FINAL path component,
  since bash can't `cd` into a file. The checker's exact repro (a lens file that is itself a symlink
  to an external payload, with a genuinely-in-bounds parent directory) still leaked the payload.
- Round 3 PASS: the fix switched to Python `pathlib.resolve()+relative_to()` on the FULL candidate
  path — the same mechanism `bin/lesson-lookup.py`'s own `_resolve_lesson_path` already uses for
  exactly this class of problem, deliberately reused rather than a third hand-rolled bash variant.
  The checker then independently tried a relative leaf symlink, a symlinked ancestor directory, and
  a shell-metacharacter lens name — all fail-closed — before passing with zero findings.

**Gate / hold decisions:** `verify-gate.sh` auto-approved at checked-sha `c34d8e639a45e30adf9fcfe151bd94a4f358fd9d`
(mechanical pass/fail, no judgment call). The merge decision itself was escalated to a genuine human
via `hold.py` (id `9f50772f`, never self-answered) — answered **merge** (sha-matched to the checked
commit) — then executed via `merge-sequencer.sh` (`0d9f995b5a522142492e643d258a5aa8eb8e857f`, pushed
to origin). No conflicts; no race recovery needed.

**Scoping decision (supervisor, pre-maker):** explicitly declined to require the adhd ideation
pass's own heavier proposals (nonce-delimited prompt fencing, a wrapper-side independent
cross-verification of the checker's self-reported `lens_coverage`) — those would have been
inconsistent gold-plating relative to the sibling normal path's own simpler trust model for the
exact same class of content (lens files / addenda are already concatenated into prompts elsewhere
in this codebase with zero nonce-fencing), and the task's own spec explicitly asked to mirror
`launch-checker.sh`'s shape, not invent a stronger one. This judgment call turned out to be
correct in substance (the checker's real findings were ordinary path-confinement bugs, not
prompt-injection-via-adversarial-content bugs) but the two real defects it DID find (both
path/symlink confinement, not nonce-fencing-shaped) came from the bash-quoting/containment-discipline
risk this consolidated plan explicitly flagged as the real surface to hammer, rather than from the
declined heavier mechanism — validating that call rather than undercutting it.
