# decision.md — decision audit trail

Append one entry per task. Format: date, task id, what the maker decided, checker findings, gates auto-approved or escalated and why.

---
## 2026-09-01 — plan-committee: --version flag

- **Maker (pi Qwen3-Coder):** implemented --version using cwd-relative `.claude-plugin/plugin.json` (wrong) and `jq -r` without null guard (wrong). Required 3 correction rounds.
- **Checker findings resolved:** (1) cwd-relative path → `SCRIPT_DIR/../` fix; (2) `jq` null → `jq // empty`; (3) selfcheck cwd inheritance; (4) SIGTERM trap with interpolated paths → function trap
- **Gates:** verify-gate refused on untracked `.secondmate/` state dir → added `.gitignore`, re-ran, PASS
- **Escalation:** none — all decisions made by supervisor
- **Herdr pane marker lesson:** use unique per-round markers (`___SM_R2_DONE_`) to avoid matching stale buffer output from previous rounds

---
## 2026-09-01 — skill: thinking medium + loop-back contract

- **Decisions:** (1) pi maker `--thinking off` → `medium`; (2) checker fail → supervisor synthesizes plan → task-scoped maker, never inline fix; (3) refused/error → escalate not loop; (4) all maker agent names task-scoped (`sm-<task-id>`); (5) visible recipe: spawn not delegate, guard on mk_pane before prompt; (6) checker recipe: --diff-base required; (7) unique round markers per checker run
- **Bugs caught by checker:** stale global agent name, README not updated, eval grader stale, hardcoded sm-maker in visible recipe, missing --diff-base in checker recipe, delegate returns no pane_id, spawn guard missing
- **Escalations:** none

---
## 2026-09-01 — plan-committee: checker-lens-quality planner prompts

- **Decisions:** (1) Replaced single generic SCHEMA with 6 per-planner functions; (2) each prompt uses outcome block (directional-prompting) + named probe categories + classification scales + Probes-for-Supervisor (STORM); (3) selfcheck uses dimension-specific markers per planner; (4) deepseek-r1 table schema marker must be table-header substring not bare word; (5) SKILL.md step 0c now requires answering all probes or escalating unanswerable ones to human
- **Bugs caught by checker:** generic selfcheck markers passed on swapped bodies → dimension-specific markers; bare-word Justification matched prose → table-header substring; SKILL.md had no escalation path for non-repo probes
- **Escalations:** none

---
## 2026-09-03 — scope-guard-hook: PreToolUse hook confining Claude maker sessions to their own worktree

- **Maker (Claude, high effort):** implemented bin/scope-guard.py to deny Bash/Read/Edit/Write/NotebookEdit calls that escape a marked maker's worktree, and deny credential-store commands (Keychain `security`, `gh auth`) unless `SM_MAKER_ALLOW_CREDS=1`. Required 6 correction rounds.
- **Checker findings resolved (rounds 1-4, real bugs, all fixed in code):** marker-deletion bypass via `rm`/interpreter-deletion → external marker outside the worktree tree, protected by scope-guard's own path confinement; Bash var-expansion + `sh -c`/`eval`/interpreter `-c`/base64-pipe bypasses → unified `_nested_command_violation` recursion covering paths+credentials+interpreter code+pipelines; crash-instead-of-deny on malformed input → wrapped decision logic to fail closed on any exception; broken `SM_WORKTREE_ROOT` env-var "persistence" (architecturally impossible — hook subprocesses don't share env across invocations) → real external marker file under `SM_MARKER_ROOT`; swallowed marker-install failure (`|| true`) → propagates and aborts spawn; no guard against marking the primary checkout → `mark-maker.sh` refuses via `--git-dir` vs `--git-common-dir` comparison.
- **Supervisor scope decisions (not bugs — deliberate boundaries, each escalated to the human first):**
  1. **pi-maker confinement gap** (round 4 finding): scope-guard.py is a Claude Code `.claude-plugin` PreToolUse hook — pi makers never load it and get zero confinement. Decision: ship Claude-side now, document the gap loudly (unmissable banner in 3 places), defer real pi-side enforcement as a separate follow-up pending investigation into pi's `--extension` capabilities (unconfirmed whether extensions can veto built-in tool calls).
  2. **Bash-heuristic completeness** (round 5 finding: `cat</etc/passwd` redirection, `xargs -0 sh -c` indirection, `python3 -c "os.system(...)"`): decision to STOP patching individual bypasses — a string/token heuristic over arbitrary Bash/interpreter code cannot be made complete (Turing-complete-adjacent problem: there is always one more encoding). Round 6 rewrote the limitation docs to name these three classes explicitly as permanent accepted limitations (alongside the already-accepted TOCTOU symlink race), rather than continuing an unbounded patch series.
- **Gates:** verify-gate PASS (`781a620`, checked-sha match, clean tree vs main) → human hold `6beac00d` ("merge and pi maker confinement risk explained") answered `merge` by the human → integrated `--no-ff` to main → worktree/branch/panes torn down.
- **Escalations:** both scope decisions above were surfaced to the human via AskUserQuestion before proceeding, not self-approved by the supervisor.
- **Side incident:** mid-task, an unrelated design bug surfaced (herdr-pane.sh splitting maker/checker panes off the supervisor's own workspace instead of the dedicated worktree workspace `herdr worktree create` provisions) — caused real interruptions when the maker pane shared a tab with the supervisor's. Spun into its own parallel task (`pane-routing-fix`) rather than blocking this one.
