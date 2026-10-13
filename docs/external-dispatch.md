# Running secondmate's dispatcher outside Claude Code

This is a replication guide for a colleague who wants to run secondmate's **top-level dispatcher**
role from an external agent — something that is not itself a Claude Code session (the task that
produced this doc used "Hermes" as a concrete example; nothing here is specific to that product, and
the pattern works from any agent that can run shell commands against this repo and talk to an LLM).

Everything below is checked against this repo's actual scripts and SOP as they exist today. It does
not reference any script or skill file that doesn't exist yet.

## 1. What this pattern is, and why

Normal secondmate dispatch (see `skills/secondmate/SKILL.md`'s "Dispatch — the standard path" and
"Dispatch mechanics — solo and batch" sections) has a Claude Code session acting as the top-level
supervisor: it recognizes the trigger, launches a fresh sub-agent-supervisor via the `Agent` tool, and
waits for that sub-supervisor's own final text to carry a completion tag.

That works, but the dispatcher itself is then just another turn inside one Claude Code session. It:

- has no OS-level exit code of its own to react to if its own process dies or gets killed between
  turns,
- can't poll a ledger file on a cron-like schedule unless it happens to be awake and taking a turn,
- can't run a watchdog that keeps checking on a sub-supervisor between the dispatcher's own turns.

**External dispatch** moves the dispatcher role to an ordinary OS-level process — a script, a bot, an
agent with a terminal — running outside any single Claude Code session. That process can:

- get a real exit code from everything it starts,
- poll `bin/progress-ledger.py`, `bin/claim-ledger.py`, `bin/pane-reaper.py`, and `bin/hold.py` on
  its own schedule (cron, a sleep loop, whatever its runtime supports),
- run a watchdog continuously, independent of any one Claude Code session's turn-taking.

Crucially, **every sub-agent-supervisor the external dispatcher spawns is still an ordinary, fresh
Claude Code session running the unmodified SOP** in `skills/secondmate/SKILL.md`. Nothing about the
maker/checker loop, the plan-committee, the checker contract, or verify-gate changes. The only thing
that moves is who starts that sub-supervisor and who watches it: an OS-level process instead of a
Claude Code `Agent` tool call.

## 2. Prerequisites

- **secondmate plugin installed** in this repo (if you're reading this file from inside the repo,
  it already is).
- **herdr**, if you want the pane-visible launch path described in §3 below (an external dispatcher
  that only needs headless sub-supervisors, with no visible pane, can skip herdr and launch Claude
  Code sessions by whatever means its own runtime supports instead — that path is outside this doc's
  scope).
- **A dispatcher agent with real terminal/shell access** — it needs to run the commands in §3 and
  §4 directly, not just converse about them.
- **A scheduler** (cron, a sleep loop, your agent runtime's own timer) for the watchdog cadence in
  §5 — nothing in this repo provides that scheduling for you; it is explicitly the external
  dispatcher's own job.

Copy-pasteable checks, run them from this repo:

```bash
gh auth status                 # needed if the dispatcher will open PRs/issues itself
git remote -v                  # confirms you're pointed at the right origin
bin/herdr-pane.sh check         # confirms herdr/HERDR_ENV wiring, if using the pane-visible path
python3 --version               # every bin/*.py script here requires python3
```

## 3. The pieces, and how they interlock

Every script below is referenced, not re-derived — the authoritative mechanics for the maker/checker
loop itself (claiming, routing, checker rounds, verify-gate, hold, merge, teardown, audit) live in
`skills/secondmate/SKILL.md`'s **"Dispatch mechanics — solo and batch"** section. What follows is only
what an external, non-Claude-Code dispatcher needs on top of that SOP.

### Launching a sub-agent-supervisor (no dedicated script — use the herdr CLI directly)

There is no `bin/spawn-*.sh` wrapper for this. The dispatcher starts a fresh Claude Code
sub-agent-supervisor as its own OS-level process the same way `skills/secondmate/SKILL.md` already
starts a **maker** inside a sub-supervisor's own loop (see SKILL.md's "Maker pane" recipe) — one level
up:

```bash
# root_pane_id comes from .result.root_pane.pane_id of a prior `herdr worktree create` call,
# exactly as SKILL.md's own maker-launch recipe uses it.
herdr agent start sm-<task-id> --kind claude --pane <root_pane_id> -- --permission-mode auto

# Submit, then harvest output with a SEPARATE call -- this repo's own established pattern
# (bin/herdr-pane.sh's `delegate` subcommand) discards `agent prompt`'s own stdout and reads the
# actual output back with `agent read` instead of trusting what `agent prompt` printed:
herdr agent prompt sm-<task-id> "<the sub-supervisor's dispatch instructions>" --wait --timeout 600000 \
  >/dev/null 2>&1 || { echo "prompt to sm-<task-id> failed or timed out" >&2; exit 1; }
herdr agent read sm-<task-id> --source recent-unwrapped --lines 400
```

`herdr agent start` returns a real process-level success/failure the dispatcher can check with its
own exit code. `herdr agent prompt --wait` gives a real exit code too, but it is **not** a reliable
"this exact turn finished" signal: `herdr agent prompt --help` says explicitly that `--wait`
"does not track turns: if the agent is already working, that active turn's completion may match" —
so a `--wait` that returns can mean a *different*, already-in-flight turn settled, not necessarily
the one this prompt just submitted. Treat `--wait`'s exit code as "something settled, go read the
real output," never as proof that the prompt you just sent is what produced it.

**Proof it worked:** `herdr agent get sm-<task-id>` returns successfully (exit 0) once the agent
exists; `herdr agent read sm-<task-id> --source recent-unwrapped --lines 400` (not `agent prompt`'s
own stdout) is what actually carries the sub-supervisor's output.

### Claiming (`bin/claim-ledger.py`)

Atomic task-id claims so two concurrently-running sub-supervisors never work the same task-id at
once. The sub-supervisor itself still runs `claim`/`release` exactly as SKILL.md's SOP already
requires — nothing about this changes under external dispatch.

```bash
bin/claim-ledger.py claim --task-id <task-id> --owner sm-<task-id>
```

**Proof it worked:** `bin/claim-ledger.py status` lists `[<task-id>] owner=sm-<task-id> ...`.

### Progress checkpoints (`bin/progress-ledger.py`)

Self-reported `{task-id, phase, ts}` checkpoints the sub-supervisor records at each SOP stage
(`claimed`, `maker_started`, `checker_round`, `verify_gate_pass`). This is the piece that matters most
for an external dispatcher: a Claude Code session with no `SessionStart` hook running inside it has no
automatic staleness surfacing. An external dispatcher must **poll this ledger itself**, on its own
schedule, to get any staleness signal at all.

```bash
bin/progress-ledger.py ready --task-id <task-id>              # at verify_gate_pass yet?
bin/progress-ledger.py stale --threshold-seconds <N> --task-id <task-id>   # too long since last checkpoint?
```

**Proof it worked:** `bin/progress-ledger.py latest` shows `[<task-id>] phase=<latest-phase> ...` for
every task-id that has recorded at least one checkpoint.

### Pane/agent liveness (`bin/pane-reaper.py`)

Detects (never acts on) a herdr pane/agent that has gone quiet, by comparing successive polls'
`(revision, agent_status, state_change_seq)` signature. It has **no `--pane-id` flag** — `observe`
takes no arguments at all, and `quiet` takes only `--threshold-seconds`. Filtering down to one pane's
output is a plain `grep -F` on its JSON-lines output:

```bash
bin/pane-reaper.py observe                              # one observation row per pane, this poll
bin/pane-reaper.py quiet --threshold-seconds <N> | grep -F "\"pane_id\": \"<root_pane_id>\""
```

**Proof it worked:** `quiet` only reports a hit once the *elapsed time since the first unchanged
observation* is `>= --threshold-seconds` — two `observe` calls 1 second apart checked against
`--threshold-seconds 3600` correctly exits 0 (no hit; 1s hasn't met the hour-long threshold yet).
To see a real hit, either pick a threshold shorter than the gap between your two observations (e.g.
two `observe` calls ~1s apart, then `quiet --threshold-seconds 1`), or wait out whatever threshold
you chose before polling `quiet` again. Only then does it exit 1 and print a
`{"pane_id": ..., "status": "quiet", ...}` line for a pane whose signature hasn't moved.

### Human gates (`bin/hold.py`)

Durable, append-only hold/answer records. An external dispatcher has no `SessionStart` hook to surface
`open` holds automatically the way an in-session supervisor does — it must poll this itself, same as
`progress-ledger.py`:

```bash
bin/hold.py open      # every unanswered hold
bin/hold.py next       # just the single oldest unanswered one
```

**Proof it worked:** after a sub-supervisor runs `bin/hold.py hold --task <task-id> --q "..." --sha
<sha>`, `bin/hold.py open` prints that question with its id.

### Merging (`bin/merge-sequencer.sh`)

Serializes concurrent merges to `main`/base across multiple sub-supervisors finishing around the same
time, re-validating freshness via `bin/verify-gate.sh` inside its own lock immediately before the real
`git merge`. The sub-supervisor itself calls this exactly as SKILL.md's SOP already specifies — once
its own hold is answered, never before.

```bash
bin/merge-sequencer.sh --repo <repo> --worktree <wt> --branch sm/<task-id> --base main \
  --checked-sha <sha>
```

**Proof it worked:** exit code `0`, and `git -C <repo> rev-parse main` has advanced past the
pre-merge SHA.

### Teardown (`bin/teardown-check.sh`)

Advisory scan for leftover per-task state: a git worktree, a git branch, a maker **agent**
(`sm-<task-id>` / `sm-pi-<task-id>`), and an open `claim-ledger.py` entry.

```bash
bin/teardown-check.sh --task-id <task-id> --repo <repo>
```

**This script does NOT cover a checker pane.** Its own header documents this as an accepted,
not-chased limitation: `_check_herdr` only ever queries agent names, never a bare visible pane with
no agent attached — which is exactly what a checker pane (opened via `herdr-pane.sh split`, per
SKILL.md's "Checker pane" recipe) is. Confirmed live: with a leaked checker-pane scenario (no maker
agent present under either name, no worktree/branch/claim left either), `teardown-check.sh` still
printed `TEARDOWN: clean` and exited 0. A checker pane is the supervisor's own responsibility to
close directly — SKILL.md's own teardown step runs `herdr pane close "$ck"` **before** worktree
removal, precisely because this script will never catch a leaked one.

**Proof it worked:** prints `TEARDOWN: clean` and exits 0 — but treat that as "worktree, branch,
maker agent, and claim are clean," never as "every herdr resource for this task-id is gone." Confirm
a checker pane was closed separately, by your own `herdr pane close` call (or `herdr pane list`
showing it gone), not by this script's report.

### Parsing completion (`bin/dispatch-report.py`)

The exit-code contract an external dispatcher's own shell script can branch on directly, instead of
re-reading a sub-supervisor's prose to make its own judgment call:

```bash
# Same submit-then-harvest split as §3's launch example -- never pipe `agent prompt`'s own stdout
# straight into dispatch-report.py.
herdr agent prompt sm-<task-id> "..." --wait --timeout 600000 \
  >/dev/null 2>&1 || { echo "prompt to sm-<task-id> failed or timed out" >&2; exit 1; }
herdr agent read sm-<task-id> --source recent-unwrapped --lines 400 > /tmp/sm-<task-id>.out
bin/dispatch-report.py /tmp/sm-<task-id>.out
echo "exit code: $?"
```

Exit codes: `0` = `SM_DONE_MERGED` (integration done), `1` = `SM_REFUSED`, `2` =
`SM_STUCK_NEED_HUMAN`, `3` = no tag found (parse failure — treat as its own escalation), `4` =
`SM_READY_UNMERGED` (reached verify-gate, not yet merged — the batch-dispatch case).

**Proof it worked:** `bin/dispatch-report.py selfcheck` prints `ok`.

## 4. First-run walkthrough, using a real completed task

The pilot task below (`fix-banner-thinking-wording`, merged as `1d3a72748dcd72f7d899506b8cdd91c203fc8bc2`
on 2026-10-13) ran through the ordinary in-session dispatch path, not an external dispatcher — but its
beats map directly onto what an external dispatcher's sub-supervisor would do, and it's useful as a
concrete reference for what each stage actually looks like end to end. The task-id, SHA, branch, and
exact timings below are **this pilot's own values** — re-derive the equivalent values for your own
run; do not copy these literally.

Per `audit/flow/2026-10-13--fix-banner-thinking-wording.md` and
`audit/decision/2026-10-13--fix-banner-thinking-wording.md`:

1. **Claim** — the task-id was claimed, then a 6-model plan-committee ran (`deepseek-r1`, `qwen3-80b`,
   `qwen3-coder`, `kimi-k3`, `mistral-large3`, `glm5`) against a known, grep-located stale-wording bug
   in `bin/session-activate.sh`'s banner.
2. **Maker** — routed to a pi maker (`global.zai.glm-5.3`, `--thinking max`) in its own worktree,
   agent name `sm-pi-banner-wording` (shortened from the full task-id to fit herdr's 32-character
   agent-name limit).
3. **Round 1** — the maker changed the banner line and added 3 selfcheck assertions, mutation-testing
   its own new assertions before replying DONE.
4. **Checker round 1 — FAIL** — the cross-model checker found a real defect: the new assert-present
   check used `grep -q` with an unescaped `.` in "5.3" (a regex metacharacter), so a corrupted banner
   like `pi+GLM-5X3` would still pass. The checker reproduced this directly: mutated the banner text,
   ran the real selfcheck, showed it wrongly printed `ok`.
5. **Round 2** — the supervisor synthesized a one-line fix plan (`grep -q` → `grep -qF` on that one
   assertion) and routed it back to the same task-scoped maker, never fixing inline. The maker
   re-ran its own mutation test to prove the gap closed, and re-verified round 1's regression tests
   still held.
6. **Checker round 2 — PASS**, zero findings, with its own independent mutation test confirming the
   fix.
7. **Verify-gate — PASS** (clean worktree, non-empty diff vs. `main`, checked-sha matched HEAD,
   selfcheck green).
8. **Hold** — `bin/hold.py hold` opened a genuine human gate (id `d149f7bb`); answered by the human
   (Eshwar) via the dispatcher chat roughly 5 minutes later. Never self-answered.
9. **Merge** — `sm/fix-banner-thinking-wording` → `main` via the merge-sequencer, landing as
   `1d3a72748dcd72f7d899506b8cdd91c203fc8bc2`, pushed to origin.
10. **Teardown** — worktree, branch, herdr pane/agent, and claim-ledger entry all released, confirmed
    clean via `bin/teardown-check.sh`.
11. **Audit** — both the flow and decision entries above were written as this task's permanent audit
    record.

Under external dispatch, steps 1–7 and 9–11 are identical — they run inside the sub-supervisor's own
Claude Code session, following the unmodified SOP. The only difference is step 8: instead of a
Claude Code `SessionStart` hook surfacing the open hold automatically, the external dispatcher's own
polling loop (§5) is what notices `bin/hold.py open` has a new entry and relays it to the human.

## 5. Troubleshooting: dispatcher-side signals

**Every row below means the same thing: relay the signal to the human verbatim. Never resolve it
yourself.** The external dispatcher has no authority to retry a stuck checker round, re-answer a hold,
or decide a quiet pane is fine — that judgment belongs to the human or to the task-scoped
sub-supervisor's own SOP, never to the dispatcher.

| Signal | Exact field/status/exit code to grep for | Shaped like completion, but is NOT | Prescribed dispatcher behavior |
|---|---|---|---|
| `progress-ledger.py stale` hit | `"status": "stale"` in a `bin/progress-ledger.py stale --threshold-seconds <N> --task-id <id>` line | — | Relay verbatim: task-id, last phase, age in seconds. |
| `progress-ledger.py` never recorded | `"status": "no_progress_recorded"` | **Yes — silence here looks identical to "nothing to report," but it means the sub-supervisor never reached even its first checkpoint.** | Relay verbatim as a possible dead-on-arrival sub-supervisor. |
| `pane-reaper.py quiet` hit | `"status": "quiet"` in `bin/pane-reaper.py quiet --threshold-seconds <N>`, filtered with `grep -F "\"pane_id\": \"<pane-id>\""` | **Yes — "quiet" is explicitly detection-only; it is never evidence of completion**, only that the pane's `(revision, agent_status, state_change_seq)` signature hasn't moved across 2+ polls. | Relay verbatim; never kill, restart, or signal the pane yourself. |
| An unanswered hold | A new line from `bin/hold.py open` or `bin/hold.py next` | **Yes — an open hold with no answer yet is silence-shaped, but it is a pending human decision, not a stall to route around.** | Relay the question + id verbatim; wait for the human's own `bin/hold.py answer`. |
| `dispatch-report.py` exit 1 | tag `SM_REFUSED:<reason>` | — | Relay the reason verbatim. |
| `dispatch-report.py` exit 2 | tag `SM_STUCK_NEED_HUMAN:<reason>` | — | Relay the reason verbatim; never attempt to unstick it yourself. |
| `dispatch-report.py` exit 3 | no recognized tag found at all | **No — this is explicitly MORE cautious than exit 2's self-reported "stuck."** | Treat as a parse failure/escalation; relay the full raw output, do not assume anything about the sub-supervisor's actual state. |
| `dispatch-report.py` exit 4 | tag `SM_READY_UNMERGED:<sha>` | **Yes — this looks like success, but it means verify-gate passed without a merge yet** (the batch-dispatch case: the dispatcher itself still owns sequencing the merge once its own consolidated hold is answered). | Fold into the batch-close set per SKILL.md's "Batch dispatch" section; do not treat it as `SM_DONE_MERGED`. |
