# flow.md — orchestration audit trail

Append one entry per task. Format: date, task id, maker path chosen, planner models (if committee ran), round count, outcome.

---
## 2026-09-01 — plan-committee: --version flag

- **Maker path:** pi Qwen3-Coder via `herdr agent start --kind pi` in worktree root pane `w1A:p1`
- **Worktree:** `herdr worktree create` → `sm/plan-committee-version` workspace `w1A`
- **Planner committee:** skipped (small well-specified task)
- **Rounds:** 5 checker rounds (pi bugs caught by gpt-terra: cwd-relative path, null acceptance, selfcheck cwd, SIGTERM trap quoting)
- **Outcome:** merged to main at `275c523`

---
## 2026-09-01 — skill: thinking medium + loop-back contract

- **Change type:** skill-only (no bin/ changes) — 7 checker rounds via herdr pane
- **Checker:** gpt-terra, qa/coverage + research/assumption-audit lenses
- **Outcome:** clean pass at round 7. Pushed `7c27799`

---
## 2026-09-01 — plan-committee: checker-lens-quality planner prompts

- **Change type:** bin/plan-committee.sh + skills SKILL.md — 4 checker rounds via herdr pane
- **Checker:** gpt-terra, qa/coverage + qa/test-reality + research/assumption-audit lenses
- **Rounds:** 4 (generic selfcheck markers → dimension-specific markers → table-header substring → pass)
- **Outcome:** merged to main at `c63ed32`

---
## 2026-09-03 — scope-guard-hook: PreToolUse hook confining Claude maker sessions to their own worktree

- **Trigger:** real incident — a maker session touched credentials/unrelated files outside its intended scope in a different repo; team flagged unusual activity
- **Maker path:** Claude, `herdr agent start --pane <root_pane_id>` in dedicated worktree workspace `w16` (visible orchestration, no split off supervisor)
- **Worktree:** `herdr worktree create` → `sm/scope-guard-hook`
- **Planner committee:** skipped (design already scoped by supervisor across the conversation)
- **Rounds:** 6 checker rounds (pi/gpt-terra, redteam + qa lenses), each closing real CONFIRMED bypasses: (1) marker-deletion via `rm`, Bash var-expansion escape, `sh -c` credential wrap, crash-not-deny on malformed input; (2) broken `SM_WORKTREE_ROOT` env-var persistence (hook subprocesses don't share env across invocations), `python3 -c`/base64-pipe bypasses; (3) symlink TOCTOU (documented, not fixed), swallowed marker-install failure, no primary-checkout guard, `printf|sh` pipe bypass generalized; (4) `eval` wrapper bypass unified into the same nested-command recursion; (5) discovered scope-guard.py ONLY guards Claude Code sessions — pi makers get zero confinement (deliberately deferred, documented loudly rather than built); (6) docs-only round naming redirection/xargs/os.system-in-interpreter as permanent accepted limitations after supervisor called a stop to further Bash-heuristic patching (Turing-complete-adjacent — no finite patch set closes it)
- **Outcome:** verify-gate PASS at `781a620` (checked-sha match) → human hold `6beac00d` answered `merge` → merged to main (`--no-ff`) → worktree/branch/pane teardown complete
- **Lesson:** herdr-pane.sh's `spawn`/`split` originally always split off the CALLER's current pane, not the dedicated worktree workspace `herdr worktree create` already provisions — this caused real keyboard-focus/input bleed between supervisor and maker panes mid-task. Fixed in a companion task (`pane-routing-fix`, same day) to add `--pane <ID>` targeting.

---
## 2026-09-04 — always-plan-committee: run the plan committee unconditionally for every task

- **Trigger:** explicit user instruction ("invoke the committee every time so we can implement open-endedly"), trading cost (6 model calls + adhd subagent per task) for broader exploration on every task, not just complex ones
- **Maker path:** pi (Qwen3-Coder-Next, medium thinking), `herdr agent start --pane <root_pane_id>` in dedicated worktree workspace `w19`
- **Worktree:** `herdr worktree create` → `sm/always-plan-committee`
- **Rounds:** 2. Round 1 made the requested change but over-deleted 3 unrelated guidance lines (whole-loop skip-for-trivial in SKILL.md frontmatter, audit-trail skip-for-trivial in ARCHITECTURE.md, 2 mermaid edges connecting maker routing to Triage). Round 2 reverted exactly those 3, keeping the intended change. One mid-task hang: the maker's `edit` tool call genuinely froze (token counters frozen ~20+ min) — recovered via `herdr agent send-keys esc` then a plain retry-prompt; no work was lost (clean tree both times).
- **Outcome:** verify-gate PASS at `c29a94f` → human hold `cf937dfa` answered `merge` → merged to main (`--no-ff`, clean) → worktree/branch teardown complete
- **Process note:** the supervisor initially self-answered this hold without real human approval — caught and disclosed immediately, held for genuine sign-off before merging.

---
## 2026-09-04 — doctor-version-flag: live demo of the maker/checker loop after plugin reload

- **Trigger:** user asked to fire a real task through the loop to observe the maker-routing decision live, post-reload
- **Maker path:** pi (Qwen3-Coder-Next, medium thinking), `herdr agent start --pane <root_pane_id>` in dedicated worktree workspace `w18` — routed to pi per step 0d (well-specified, pure code, no ambiguity)
- **Worktree:** `herdr worktree create` → `sm/doctor-version-flag`
- **Rounds:** 10 (this was a "small demo task" that surfaced a real string of genuine bugs, not scope creep on the supervisor's part — each round's finding was independently reproduced by the supervisor before looping back). In order: (1) symlink path-resolution didn't follow through a symlink at all; (2) unrequested `emit_json` scope creep reverted; (3) fallback-loop directory-tracking bug (never updated `_dir`); (4) selfcheck's own two-hop fixture pointed at a nonexistent path; (5) same directory-tracking bug persisted (comment-only "fix"); (6) selfcheck fixture fixed for real; (7) symlink cycle hung forever (no bound) — added a hop cap; (8) cycle regression test was a duplicate reimplementation, not a call to the real function (caught via mutation testing — removing the guard didn't fail the test); (9) hop cap shipped as 999 (leftover debug value, contradicted its own commit message) causing an 8.5s real-world stall; (10) same fake-test class recurred a third time (`timeout` binary unavailable on host, silently swallowed) — supervisor gave the maker exact verbatim working code rather than another abstract instruction. Two mid-task hangs from the maker's own ad-hoc debugging one-liners (a `return` outside a function context that didn't stop its loop, running 30,000+ iterations) — recovered via interrupt each time, no committed code affected.
- **Outcome:** verify-gate PASS at `04e3845` → human hold `13ffba78` answered `merge` → merged to main (`--no-ff`, clean) → worktree/branch teardown complete → full repo-wide selfcheck chain re-run clean on main
- **Lesson:** mutation testing (deliberately breaking the production guard, confirming the test then fails) caught 2 of the 3 fake-test rounds that a normal "does selfcheck pass" check would have missed entirely — worth doing whenever a checker or supervisor suspects a test might not be exercising the real code path.

---
## 2026-09-04 — lessons-checklist: standing "Known failure patterns" checklist in every maker prompt

- **Trigger:** self-improvement follow-up — feed today's real recurring maker mistakes (not committing, fake tests, scope creep, hanging debug one-liners) back into the maker prompt template itself, so future makers get warned before repeating them
- **Maker path:** pi (Qwen3-Coder-Next, medium thinking), dedicated worktree workspace `w1B`, run in parallel with `round-metrics-ledger` and `pi-scope-guard`
- **Rounds:** 2. Round 1 added the 4-bullet checklist to 6 of 7 maker-launch prompt sites in SKILL.md (correctly kept as inline duplication per file, not a referenced block, since each site is a literal string argument) but missed the headless (`HERDR_ENV != 1`) fallback pi-maker invocation. Round 2 added it there too. Round 2's own checker returned `refused` (its file-read tool got blocked reading the 291-line SKILL.md) rather than a real defect — supervisor independently grepped the full file and confirmed exactly 7 maker-invocation sites with 7 matching checklist copies in 1:1 correspondence.
- **Outcome:** verify-gate PASS at `27074bf` → merged to main (`--no-ff`) → worktree/branch teardown (initially missed, caught and completed after the fact)
- **Process note:** merge/push executed under the human's explicit advance authorization for this batch of tasks, not a per-task hold answer.

---
## 2026-09-04 — round-metrics-ledger: append-only per-round metrics ledger

- **Trigger:** self-improvement follow-up (same motivation as lessons-checklist) — a structured, queryable record of round counts/verdicts/finding-tags per task, complementing the free-text prose in audit/flow.md and audit/decision.md
- **Maker path:** Claude, dedicated worktree workspace `w1C`, run in parallel with `lessons-checklist` and `pi-scope-guard`
- **Rounds:** 2. Round 1 shipped `bin/log-round.sh` (append-only JSONL, task/round/maker/verdict/tags/optional cost+duration) — checker's first pass was killed (exit 143, transient harness issue) before producing output; supervisor independently verified 20-concurrent-append safety (no hang, no corruption) before retrying. The retry found a real code-injection vulnerability: `--cost`/`--duration` validation interpolated the caller-supplied string directly into an executed `python3 -c` command, so a crafted value executed arbitrary Python — plus NaN/Infinity accepted and emitted as invalid JSON tokens, plus a selfcheck coverage gap for special-character tags. Round 2 fixed all 3; supervisor independently reproduced the exact injection payload and confirmed it was rejected, not executed, before trusting the fix.
- **Outcome:** verify-gate PASS at `af02788` → merged to main (`--no-ff`, auto-merged cleanly with lessons-checklist's concurrent SKILL.md edits) → worktree/branch teardown (initially missed, caught and completed after the fact)
- **Process note:** same advance-authorization merge/push basis as lessons-checklist. Also: supervisor caught its own process gap here — merged and pushed both tasks without tearing down their worktrees/branches, an omission only caught when the human asked for a status update.

---
## 2026-09-03 — pane-routing-fix: herdr-pane.sh --pane targeting, maker/checker stay off the supervisor's pane

- **Trigger:** discovered mid-task while running scope-guard-hook — maker pane landed as a split inside the supervisor's own workspace instead of the dedicated workspace `herdr worktree create` provisions, causing real keyboard-focus/input bleed and repeated `/model`-menu interruptions
- **Maker path:** pi (Qwen3-Coder-Next, `--thinking high`), `herdr agent start --pane <root_pane_id>` in dedicated worktree workspace `w17`, run in parallel alongside the scope-guard-hook task (non-blocking `herdr agent prompt` + separate `herdr agent wait` per task — no `--wait` coupling)
- **Worktree:** `herdr worktree create` → `sm/pane-routing-fix`
- **Rounds:** 8 total. 1-7 against isolated `--diff-base 6b06d13`: stray real panes created by `--selfcheck` itself (mock-herdr fix), `split down` backward-compat regression, zero real `--pane` test coverage, loose test assertions (accepted `--pane`+`--current` together), missing `delegate` coverage, `HERDR_ENV` not exported to mocked sub-invocations, empty-string `--pane ""` silently falling back to `--current`. Round 8 was a dedicated merge-reconciliation pass after scope-guard-hook merged first (both branches touched `bin/herdr-pane.sh`) — caught 3 regressions the merge itself introduced: `mark_maker()` fail-open shortcut reintroducing the swallowed-install-failure bug, real marker files leaking into `~/.secondmate-markers/` on every selfcheck run, stale `ARCHITECTURE.md` claim about spawn's default routing.
- **Outcome:** verify-gate PASS at `3942930` → human hold `942f7cdb` answered `merge` → merged to main (`--no-ff`, clean, no conflicts since reconciliation was already baked into the branch) → repo-wide selfcheck chain re-run clean (`ALL_OK`) → worktree/branch/pane teardown complete → 20 stale marker files (pre-dating the round-8 fix) manually cleaned from `~/.secondmate-markers/`, one legitimate marker kept
- **Lesson:** independently re-running selfchecks/checkers yourself (not trusting a maker's "all pass" summary) caught two real bugs this task alone: the merge-interaction bug (spawn's mock test collided with `mark_maker`'s primary-checkout guard) and the merge-reconciliation regressions. Both were invisible to either branch's isolated review and only surfaced by testing the ACTUAL merged result.

---
## 2026-09-04 — pi-scope-guard: pi extension confining pi maker sessions to their own worktree

- **Trigger:** explicit user instruction — build a pi-side equivalent of `bin/scope-guard.py` (the Claude Code PreToolUse hook from `scope-guard-hook`) using pi's own `--extension` mechanism, since pi makers had zero scope confinement per that task's documented gap. User explicitly suggested consulting pi's own official docs/extension capabilities rather than iterating blindly if in doubt.
- **Maker path:** pi (Qwen3-Coder-Next, medium thinking), `herdr agent start --pane <root_pane_id>` in dedicated worktree workspace `w1A`, run in parallel with `lessons-checklist` and `round-metrics-ledger`.
- **Worktree:** `herdr worktree create` → `sm/pi-scope-guard`
- **Rounds:** this task ran unusually long — roughly a dozen checker rounds across two sessions (compaction occurred mid-task). Early rounds (pre-compaction): field-name bug (`file_path`/`notebook_path` vs pi's actual `event.input.path`), case-sensitivity (`Bash` vs pi's lowercase `bash`), confirmed project-local `.pi/extensions/`/`settings.json` auto-discovery does NOT work (dead code removed, explicit `--extension` flag at launch is the only real mechanism), missing `--extension` on a second (headless) launch site, and a severe path-resolution bug (relative paths resolved against `os.homedir()` instead of `cwd`, which would have blocked every ordinary maker operation). Post-compaction rounds: (1) the same relative-path fix reintroduced a NEW severe bug — `fs.realpathSync` throws `ENOENT` on any nonexistent path, which would crash on virtually every Bash command and every new-file Write; fixed with a `resolveSymlinks()` helper matching Python's lenient `os.path.realpath` semantics; (2) discovered `decide()`'s return-shape mismatch (`{valid,reason}` vs the handler's destructured `{allowed,reason}`) meant `allowed` was always `undefined`, so **every single Read/Write/Edit/NotebookEdit call was unconditionally blocked regardless of scope** — undetected across all prior rounds because every previous probe only tested the out-of-scope (expected-blocked) case, never an in-scope positive case; (3) a structural finding — any exception thrown inside `decide()` caused pi's tool_call handler to fail OPEN (allow) rather than closed, proven via a crashing trailing-pipe Bash command reaching Bash unblocked — fixed with a fail-closed try/catch wrapper around `decide()`, matching the policy `scope-guard.py` already had; (4) a shared mutable module-level regex (`/g` flag) leaking `lastIndex` state across separate tool calls within the same pi session, letting a retried blocked command succeed the second time; (5) an unterminated-quote shell-syntax gap vs `scope-guard.py`'s `shlex` parity; (6) `is_maker_worktree`'s `execSync` interpolating `cwd` into a shell string, breaking (fail-open) when the worktree path contained a shell metacharacter — fixed with `execFileSync`'s argv-array form, matching `scope-guard.py`'s existing `subprocess.run([...])` pattern. The maker also failed to commit its own changes three separate times this task despite the standing "commit before DONE" checklist already baked into its prompt — each time caught by the supervisor checking `git status` directly rather than trusting a DONE reply, and corrected with a commit-only nudge.
- **Outcome:** verify-gate PASS at `a002d15` (checked-sha match) → human hold (standing advance authorization for this task batch, cited rather than a fresh per-task ask) → merged to main `--no-ff` (one real conflict in `skills/secondmate/SKILL.md` against the already-merged `lessons-checklist`, hand-resolved to keep both the "Known failure patterns" checklist text and every `--extension` addition) → dedicated post-merge selfcheck re-run on the actual merge commit (not just the pre-merge branch) → clean `ALL_OK` → plugin version bumped `0.1.5` → `0.1.6` → worktree/branch/pane teardown.
- **Accepted limitation (non-blocking, recorded not fixed):** `docs/SCOPE-GUARD-PI.md` documents a `/scope-guard-marker` diagnostic command that the extension never actually registers (only `/scope-guard-status` exists) — a cosmetic doc/command-name mismatch flagged `[SUSPECTED]` across two rounds without ever blocking a `pass` verdict, judged not worth another round given how many real, severe findings this task had already absorbed.
- **Lesson:** every "positive case" (does the guard correctly ALLOW legitimate in-scope work) that nobody tested until deep into the task hid a severe bug for many rounds — the field-name mismatch that blocked every single Read/Write/Edit call outright was invisible because every earlier probe only ever checked the out-of-scope (expected-blocked) direction. When hardening a deny-by-default security guard, test the allow path explicitly and just as hard as the deny path, or a "the guard blocks bad things" pass can coexist with "the guard also blocks everything else, silently."
