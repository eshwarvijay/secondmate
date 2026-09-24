## 2026-09-11 — fix-doctor-status-line: distinguish reload_pending from stale in doctor.sh's STATUS line (fan-out live validation)

- **Trigger:** live, real end-to-end validation of the newly-built "Fan-out to concurrent sub-supervisors"
  pattern (SKILL.md) — this task was one of (at most) 2 concurrent tasks run under a fresh sub-supervisor
  agent, sibling to `fix-scope-guard-marker-doc`, both dispatched from a single top-level Agent-tool call.
- **Maker path:** pi (Qwen3-Coder-Next, medium thinking), dedicated worktree workspace `w29`, root pane
  `w29:p1`. One round, no correction needed.
- **Worktree:** `herdr worktree create` → `sm/fix-doctor-status-line`.
- **Planner committee:** ran unconditionally (6 pi planners), per this repo's standing rule. All 6 converged
  on the same minimal fix ("Option A": a distinct `reload_pending_count` counter + one new `elif`); glm5's
  own output was weak/truncated and discarded as noise per the synthesis step's own instruction. Every probe
  the committee raised (precedence ordering, whether a hidden running-state cache file exists, whether
  `_reset_detect_state()` needs updating, whether README/ARCHITECTURE need edits) was answered directly from
  the actual code before the maker was ever prompted — no OPEN DECISIONs, no escalations needed.
- **Rounds:** 1 checker round (`global.openai.gpt-5.6-terra`, `qa/coverage` + `qa/test-reality` lenses),
  clean pass, zero findings — but the round had to be run twice due to a real infrastructure bug discovered
  along the way (see below); the second run was the clean, trusted one.
- **Real infrastructure bug found and fixed mid-task (not a doctor.sh bug):** `herdr-pane.sh split --pane
  <root_pane_id> --dir down` does **not** cause the new pane's shell to inherit the root pane's cwd — the
  split pane's ambient shell started in the primary checkout (`/Users/eshwar.vijay/secondmate`), not the
  worktree, even though it was split off that worktree's own root pane. Combined with `launch-checker.sh`'s
  `--repo` flag only scoping the *diff computation*, not the checker agent process's own cwd (it `exec`s the
  harness with no `cd`/`--cwd`), the checker's first invocation ran against the wrong location entirely. The
  checker itself detected and transparently disclosed this in its verdict envelope's `diagnostic` field,
  self-corrected via `git archive <sha> | tar -x` into a scratch dir, and still produced a legitimate pass —
  but the supervisor re-ran the round with an explicit `cd <worktree> &&` prefixed to the checker script for
  an unambiguous second pass (also clean) rather than trusting the workaround alone. **This means every prior
  task's "split a pane off the worktree's root pane" checker recipe in this repo's history may have silently
  relied on the same lucky self-correction or gone undetected** — worth fixing structurally (always `cd` the
  worktree explicitly inside the checker script, never assume pane cwd) rather than patched per-task.
- **Real infrastructure bug found and fixed mid-task (not a doctor.sh bug, #2):** `bin/merge-sequencer.sh`
  refused to merge — correctly, per its own designed dirty-repo guard — because the primary checkout had 2
  untracked files: `audit/merge-ledger.jsonl` (merge-sequencer's own ledger, already accumulating 3 prior
  merges' worth of history, never gitignored) and `audit/metrics.jsonl` (`bin/log-round.sh`'s own output,
  freshly created by this task's own round-1 logging call). Neither is source, neither was ever committed or
  gitignored across this repo's entire history of using both scripts. Fixed with the same minimal precedent
  already set by this repo's very first task (`plan-committee: --version flag`, which hit the identical class
  of problem with `.secondmate/` and fixed it by adding a `.gitignore` entry): added both paths to
  `.gitignore`, committed directly to the primary checkout (`49418bd`, verified no merge-sequencer lock was
  held at the time — no race with the concurrent sibling task), then retried the merge successfully. This
  unblocks every future `merge-sequencer.sh` invocation in this repo, not just this task's.
- **Fan-out pattern itself — worked as documented, one genuine hold-wait cycle exercised for real:** claimed
  via `claim-ledger.py` first (token minted, released on the terminal path); derived all names deterministically
  from the task-id; ran the full solo SOP untouched; opened its own hold (`b42c2ebb`) bound to the checked-sha
  and **genuinely stopped**, emitting `SM_STUCK_NEED_HUMAN` with the hold id and exact question, rather than
  assuming or fabricating an answer — the top-level dispatcher relayed a "resume" message later in the same
  session, which was independently re-verified against `bin/hold.py open` (showed no open decisions) AND the
  raw `decisions.jsonl` ledger record (`{"ev":"answer","id":"b42c2ebb",...,"a":"merge"}`) before proceeding,
  per the pattern's own explicit "do not just trust the message's claim" instruction.
- **Outcome:** verify-gate PASS at `eb7926f` (checked-sha match) → hold `b42c2ebb` answered `merge` (genuine,
  independently re-verified from the raw ledger before acting) → merged to main via `bin/merge-sequencer.sh`
  at `664b1c8`, pushed → full repo-wide selfcheck re-run clean on the actual merged commit → worktree
  (`w29`)/branch/pane torn down → claim released.
- **Lesson:** this task is the first real, end-to-end exercise of both the fan-out pattern's hold-wait-resume
  cycle AND its "sub-supervisor handles its own merge, including any blockers it hits along the way" design —
  and it surfaced two genuine, previously-undetected infrastructure gaps (the pane-cwd assumption and the
  merge-sequencer gitignore gap) purely as a side effect of actually running the pattern for real rather than
  reading it. Both gaps were latent in every prior task that used the affected recipes; neither had been
  exercised in a way that surfaced them until this task's specific sequence of operations (splitting a
  checker pane AND being the first task since `round-metrics-ledger` to call `log-round.sh` from a repo whose
  `merge-ledger.jsonl` had already accumulated real history) lined up to expose them.
