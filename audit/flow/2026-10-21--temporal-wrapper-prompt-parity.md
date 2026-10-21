## 2026-10-21 — temporal-wrapper-prompt-parity: closed gaps 3/5 fully, gap 4 text-parity with an honest headless-ponytail asymmetry

## Flow — temporal-wrapper-prompt-parity

Solo dispatch, full secondmate SOP. Scope: close gaps 3/4/5 in `bin/run-round-temporal.sh` (the
opt-in Temporal-engine maker/checker-round wrapper) by changing only prompt-text construction in
that one script — hard scope boundary: zero touches, including zero read-only edits, to
`/Users/eshwar.vijay/coupa/temporal-local-fork/bridge` (a concurrent sibling task,
`configurable-maker-checker`, owned that repo for the duration).

**Plan committee:** ran the 6-model `plan-committee.sh` (deepseek-r1, qwen3-80b, qwen3-coder,
kimi-k3, mistral-large3, glm5) — 5/6 succeeded (qwen3-80b timed out/produced empty output; its
architecture-dimension ground was substantially covered by qwen3-coder + kimi-k3, so not retried).
Also dispatched a fresh general-purpose agent to run the `adhd` skill for divergent ideation
(5 cognitive frames → clustered → converged on a 4-item shortlist with traps called out). All
outputs under `.secondmate/planning/temporal-wrapper-prompt-parity/`. Synthesized into
`CONSOLIDATED.md` in the same directory: resolved every raised probe directly from the repo (no
business/product escalations needed) — most load-bearing: direct read-only verification against
the bridge's own `maker.go`/`checker.go` confirmed `BRIDGE_CHECKER_PROMPT`/`BRIDGE_CHECKER_ENVELOPE`
are already wired in unchanged, and the ONLY per-round text channel into the checker's prompt is
`params.goal` (`"Goal: " + goal`) — so lens content had to land in `checker_goal_full`, never the
bare `checker_goal` used verbatim in the commit message. Also deliberately declined the adhd
branch's heavier nonce-fencing / wrapper-independent lens_coverage-cross-check proposal as
inconsistent gold-plating versus the sibling normal path's own simpler trust model (launch-checker.sh
itself does plain `--append-system-prompt` injection with no nonce-fencing) — ponytail-ultra bias
toward the smallest correct change, mirroring existing patterns exactly.

**Maker routing:** Claude maker (complex/judgment task: careful shell-quoting discipline,
security-sensitive injection surface, multi-file doc sync) on the worktree's root_pane via
`herdr agent start/prompt`, `--permission-mode auto`. Worktree `sm/temporal-wrapper-prompt-parity`
created+marked+skills-synced via the standard herdr worktree flow.

**Rounds (3 total, cross-model GPT checker, base discipline + `redteam/injection` lens, visible
herdr pane per the `HERDR_ENV=1` strict-visibility rule):**
- Round 1 (maker commit `b46e5e6`): checker **FAIL** — two CONFIRMED defects: (1) `--lens`
  path-traversal (`../../../../tmp/evil` escaped `bin/lenses/` entirely, since the only check was a
  bare `[ -f ]` existence test); (2) a `round-state.md` with no trailing newline glued directly into
  the following lesson-lookup.py output with no separator (lost SKILL.md's implicit `echo`-newline
  when the command-substitution template was converted to real bash).
- Round 2 (fix commit `d9d3406`): checker **FAIL** — the round-1 fix (`cd $(dirname)+pwd -P`
  containment) only resolved the lens file's PARENT directory, not the final path component, so a
  lens file that was itself a symlink to an external file still escaped.
- Round 3 (fix commit `c34d8e6`, using Python `pathlib.resolve()+relative_to()` on the full
  candidate path — mirroring `bin/lesson-lookup.py`'s own existing `_resolve_lesson_path` pattern
  exactly): checker **PASS**, zero findings, after independently re-probing several more escape
  shapes unprompted (relative leaf symlink, symlinked ancestor directory, shell-metacharacter lens
  name) and byte-for-byte diffing the injected boilerplate against SKILL.md's own section.

**Gate:** `verify-gate.sh` PASS at checked-sha `c34d8e639a45e30adf9fcfe151bd94a4f358fd9d` (clean
tree, non-empty diff vs `main`, checker-current, `--selfcheck` green).

**Hold:** opened my own durable hold (`9f50772f`), never self-answered — a human answered `merge`
(sha-matched) after I handed back SM_STUCK_NEED_HUMAN. Merged via `merge-sequencer.sh` as
`0d9f995b5a522142492e643d258a5aa8eb8e857f` (pushed to origin). Teardown (pane/worktree/branch/claim)
confirmed clean via `teardown-check.sh`.

**Outcome:** gaps 3 (`--lens`) and 5 (lesson-injection + optional `--task-id`) fully closed and
verified end-to-end. Gap 4 (maker-prompt-closing-boilerplate) closed for text parity on every maker
prompt, with one honest, documented, non-closable-in-scope asymmetry: the injected
ponytail-at-ultra-intensity instruction (per a live mid-task correction from the dispatching
supervisor, overriding the skill's bare default) is genuinely actionable only on the herdr-visible
maker branch (`--herdr-task-id` given, a real interactive `claude` agent) — inert text on the plain
headless branch, since the bridge's `maker.go` hardcodes `--allowedTools Read,Edit,Write,Bash` with
no Skill tool at all (verified read-only). No live bridge round was run (maker's sandbox blocked any
path outside its own worktree); confidence rests on `--selfcheck` plus the checker's own direct
adversarial probing of the real assembled plan JSON.
