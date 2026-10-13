---
name: secondmate-dispatch
description: >
  Dispatcher role for an EXTERNAL top-level process running OUTSIDE Claude Code — e.g. Hermes, or
  any agent with terminal access + a scheduler — that holds the same solo/batch dispatch contract
  skills/secondmate/SKILL.md's own "Dispatch mechanics — solo and batch" section already defines
  for an in-session Claude Code Agent-tool dispatcher, but spawns OS-level `claude -p` processes
  (one fresh, zero-inherited-context process per sub-agent-supervisor) instead of Agent-tool calls.
  Use when the top-level dispatcher itself is NOT a Claude Code session — it has no Agent tool, no
  ScheduleWakeup, and can only observe a sub-supervisor's progress by watching files and processes
  on disk. Do NOT use this for ordinary in-session dispatch from inside Claude Code — that stays
  exactly as documented in skills/secondmate/SKILL.md, untouched by this file.
---

# secondmate-dispatch — external OS-process dispatcher

## Scope

This file is for a dispatcher process that is itself **not** a Claude Code session: a cron job, a
long-running shell daemon, Hermes, or any other agent/scheduler with terminal access. It spawns
each sub-agent-supervisor as a separate OS process (`claude -p ...`) rather than an Agent-tool
call, and it has no `ScheduleWakeup`, no in-session hold UI, and no Agent-tool return value — only
files on disk and process exit codes. `skills/secondmate/SKILL.md` is the single source of truth
for everything about *what* the sub-supervisor does once it is running (Plan Committee, Triage,
Spawn, Guard, Check, Gate, Hold, Integrate, Teardown, Audit trail, Lesson feedback) — that file's
in-session Agent-tool top level is unedited and unaffected by this one. This file covers only what
changes for *how the dispatcher itself launches, watches, and closes out* that same contract when
it is an external OS process instead of an Agent-tool call.

## The same contract, restated briefly

Read `skills/secondmate/SKILL.md`'s "Dispatch mechanics — solo and batch" section before using this
file — it is not reproduced here beyond this pointer summary:

- **Trigger test** — dispatch (never run the loop inline) once a task is iterative (multiple
  edit→check rounds) **and** verifiable (tests/build/lint/a live call proves it) **and**
  risky/outward-facing (commit, push, PR, deploy, delete, external write). All three must hold.
- **Batch cap** — at most **10** concurrent sub-supervisors per batch, a hard, non-tunable constant
  (`N=10`). More than 10 independent tasks: run 10 now, queue the rest for the next batch.
- **Solo vs. batch** — one task → solo dispatch, one fresh sub-supervisor, its own hold, its own
  merge. Several genuinely independent tasks handed over together → batch dispatch, up to 10 fresh
  sub-supervisors, **one** consolidated human hold for the whole batch, not one per task-id.
- **Solo sub-supervisor steps 1–7** and **batch sub-supervisor steps (a)–(d)** are unchanged —
  claim → derive names → run the existing solo SOP, recording `progress-ledger.py` checkpoints →
  (batch only) stop at `SM_READY_UNMERGED` instead of self-merging → release claim (solo) or leave
  it open (batch, until the consolidated hold is answered) → emit exactly one completion tag.
  See that section for the exact `claim-ledger.py`/`progress-ledger.py` invocations at each step.

Everything below is what is genuinely different when the dispatcher is an external OS process.

## 1. Spawning a sub-supervisor: `bin/spawn-sub-sup.sh` contract

`bin/spawn-sub-sup.sh` does not exist in `bin/` yet — a sibling task (`add-spawn-sub-sup-script`)
running concurrently with this one owns building it. The contract below is what that script must
implement and what this skill's recipes call; it is not invented here, and the dispatcher must not
assume a different shape than this.

**Invocation:**
```
bin/spawn-sub-sup.sh --task-id <task-id> --prompt-file <path> --log-dir .secondmate/dispatch
```

**Inputs:** a `--task-id` (validated by the dispatcher before the call — see Discipline below), a
`--prompt-file` holding the full sub-supervisor prompt (claim → SOP → completion tag, same prompt
shape as the Agent-tool version, plus the `SM_CLAIM_TOKEN:` line required below), and a `--log-dir`.

**Behavior, in order:**
1. Fork a **brand-new** `claude -p --output-format stream-json` process for that task-id and
   prompt. Never `--continue` or `--resume` — every sub-supervisor must start with zero inherited
   context, the exact same "Agent tool, never fork" discipline `skills/secondmate/SKILL.md` already
   requires for the in-session case, just enforced via process flags instead of a tool-call
   parameter. Then — as the very first action the parent takes once the child's PID is available,
   before anything else — write a `<task-id>.pid` liveness sidecar into the log dir containing that
   PID and the fork's own timestamp (e.g. `pid=<N> forked_at=<epoch-seconds>`, or a `date`-sourced
   equivalent). **Not "before forking":** a PID cannot be known before the child exists — in bash,
   `$!` (the backgrounded child's PID) is empty until after the `&` fork has already happened
   (confirmed live: a probe script printed `$!` as empty immediately before forking a background
   `sleep`, and only non-empty immediately after). The sidecar write happens immediately after the
   fork instead, with a small, unavoidable window between fork and sidecar-write — normal and fine
   for this idiom, same as any PID-file scheme. The `forked_at` timestamp is written here because
   section 5's liveness check needs it later to corroborate that whatever process is holding this
   PID at check time is actually still *this* task's wrapper, not a reused/unrelated PID (see
   section 5). This sidecar is independent of `progress-ledger.py`'s self-reported checkpoints: it
   gives the watchdog (section 4) a liveness signal even if the sub-supervisor dies before ever
   recording its first checkpoint.
2. Tee the raw `stream-json` output to `.secondmate/dispatch/<task-id>.jsonl` as it streams.
3. On process exit, extract the final assistant message's plain-text content out of that
   `stream-json` log into `.secondmate/dispatch/<task-id>.final.txt`.
4. Run `bin/dispatch-report.py` against that `.final.txt` file — **never** the raw `.jsonl`.
   `dispatch-report.py`'s own completion-tag regex is anchored at the start of a line; a completion
   tag that happens to appear inside a JSON string value in the raw stream (e.g. quoted inside a
   `"text": "...SM_DONE_MERGED:abc123..."` field) would never match there, so only the extracted
   plain text is a valid target.
5. Exit with `dispatch-report.py`'s own exit code **verbatim** — never a raw bash `$?` from the
   `claude -p` process itself (that reflects the CLI's own exit status, not the parsed completion
   tag).

**Outputs:** `.secondmate/dispatch/<task-id>.jsonl` (raw), `.secondmate/dispatch/<task-id>.final.txt`
(extracted plain text), `.secondmate/dispatch/<task-id>.pid` (liveness sidecar).

**Exit code:** `dispatch-report.py`'s own exit code, relayed unchanged — the full set is
0/1/2/3/4: `0` = `SM_DONE_MERGED` (integration already done), `1` = `SM_REFUSED` (relay the reason),
`2` = `SM_STUCK_NEED_HUMAN` (relay the reason verbatim), `3` = no completion tag found at all
(malformed — treat as an escalation-worthy parse failure), `4` = `SM_READY_UNMERGED` (batch dispatch
only — reached verify-gate PASS, awaiting the batch's consolidated hold, NOT yet merged). `0` and `4`
must never be conflated: a batch sub-supervisor that only reached verify-gate PASS has not merged
anything, and `spawn-sub-sup.sh` must propagate exit `4` unchanged rather than collapsing it toward
`0`/success. See `bin/dispatch-report.py` and `skills/secondmate/SKILL.md`'s own exit-code contract
for the full detail.

## 2. Log convention

Every spawned sub-supervisor leaves exactly two log artifacts under `.secondmate/dispatch/`:
- `<task-id>.jsonl` — the raw `stream-json` transcript, append-only, useful for a human reading back
  what actually happened.
- `<task-id>.final.txt` — the extracted plain-text content of the final assistant message only.
  This is the ONLY file the dispatcher parses programmatically — both for `dispatch-report.py`
  (section 1) and for the claim-token line (section 3).

## 3. Extracting the claim token

The sub-supervisor claims its task-id inside its own fresh process (`bin/claim-ledger.py claim
--task-id <id> --owner sm-<id>`), which prints `token=<hex>` to that process's own stdout — but the
external dispatcher never sees that process's live stdout, only the extracted `.final.txt`. So
every sub-supervisor's prompt must instruct it to also emit a dedicated line in its final output:
```
SM_CLAIM_TOKEN:<the hex token claim-ledger.py printed>
```
This is a **separate** line from the completion tag — `dispatch-report.py`'s own tag regex only
recognizes `SM_DONE_MERGED` / `SM_REFUSED` / `SM_STUCK_NEED_HUMAN` / `SM_READY_UNMERGED` and does
not look for `SM_CLAIM_TOKEN:` at all. The dispatcher extracts it itself:
```bash
token=$(grep '^SM_CLAIM_TOKEN:' ".secondmate/dispatch/${task_id}.final.txt" | head -1 | cut -d: -f2-)
```
The dispatcher needs this token later for `bin/claim-ledger.py release` at merge/teardown time
(section 7) — without it, a claim opened inside a sub-supervisor's own disposable process can never
be released from outside that process.

## 4. Watchdog cadence for an external process

`ScheduleWakeup` is in-session-only — an external dispatcher has no equivalent, so the watchdog is
a plain polling loop calling the exact same primitives `skills/secondmate/SKILL.md` already
documents, on the same detection-only, relay-verbatim discipline (never auto-restart, never
auto-`--steal`):

```bash
while true; do
  bin/progress-ledger.py stale --threshold-seconds "$N" "${task_id_flags[@]}"
  # the .pid sidecar liveness check (section 1/5) is the ALWAYS-available signal, no herdr required —
  # poll it here too, non-blocking (kill -0), for any task-id whose .final.txt hasn't appeared yet
  if command -v herdr >/dev/null 2>&1; then
    bin/pane-reaper.py observe
    bin/pane-reaper.py quiet --threshold-seconds "$N" | grep -F -e "\"pane_id\": \"${root_pane_id}\"" ...
  fi
  # relay any hit from either call to the human verbatim, exactly as the in-session watchdog does —
  # never restart, never steal, never treat a hit as a confirmed crash
  sleep "$N"
done
```

**`pane-reaper.py` requires herdr; guard it.** This dispatcher's own Scope section above only
requires "terminal access + a scheduler" — herdr is optional infrastructure, not a hard dependency.
`pane-reaper.py observe` shells out to `herdr pane list` internally and has no fallback: run it on a
`PATH` with no `herdr` binary and it exits 2 with `could not run \`herdr pane list\`: [Errno 2] No
such file or directory: 'herdr'` (confirmed live). Guard both `pane-reaper.py` calls behind
`command -v herdr >/dev/null 2>&1`, exactly as shown above, so a herdr-less deployment of this
dispatcher doesn't fail its watchdog loop outright. The liveness signal that works with **no**
herdr dependency at all is the `.pid` sidecar check described in section 5 below — the watchdog
should always rely on that regardless of whether herdr happens to be present.

The loop itself — not any cron/launchd/systemd entry — is the portable unit; it can run under a
plain `nohup`/`tmux` session anywhere. A scheduler entry may optionally backstop it (e.g. checking
that the loop's own heartbeat file has advanced recently and restarting the *loop process* if not),
but that backstop is optional infrastructure around the loop, not a substitute for it.

## 5. Batch close and the batch manifest

**Primary signal: each task-id's own `spawn-sub-sup.sh` process exiting.** Unlike the in-session
case (where the dispatcher's own Agent-tool call return is the signal), the external dispatcher
tracks each task-id's terminal outcome via its process's exit — section 1's contract: it relays
`dispatch-report.py`'s exit code (0/1/2/3/4) verbatim — which IS the terminal-outcome signal for
that task-id, whatever the code is. This is NOT optional, and `bin/progress-ledger.py ready
--batch-id <batch-id>` is NOT a substitute for it: `ready`'s own implementation only emits a
task-id whose *latest recorded phase* equals the terminal `verify_gate_pass` phase (confirmed by
reading `progress-ledger.py`'s `ready` command directly) — a refused or stuck task-id, whose
sub-supervisor released its claim and exited without ever reaching that phase, never appears in
`ready`'s output at all, not even as a non-ready hit. A dispatcher that only polled `ready` would
wait out the full batch TTL for every refused/stuck task-id instead of recognizing them as already
terminal the moment their process exited.

**Reaping that exit is restart-safe — never a blocking `wait <pid>`.** The dispatcher process that
originally forked a task-id's `spawn-sub-sup.sh` could `wait` on it directly, but a dispatcher that
restarted mid-batch (crash, redeploy, manual kill) only has the batch manifest (below) to work
from, and a shell can only `wait` on its own child — waiting on a PID it never forked itself fails
immediately (confirmed live: `wait <pid>` from a fresh shell that did not fork that PID returns
exit 127, `pid <N> is not a child of this shell`). So reaping, for every dispatcher — restarted or
not — is a non-blocking poll on the loop's own cadence (section 4), per task-id, **checking PID
liveness FIRST, not `.final.txt` presence first:**

1. **Is the `.pid` sidecar's recorded PID still alive and still plausibly this task's wrapper?**
   `.final.txt`'s mere presence does NOT prove the wrapper has finished: per section 1's own step
   order, the wrapper writes `.final.txt` at step 3, then still has to run `dispatch-report.py`
   (step 4) and exit with its code (step 5) — so `.final.txt` can exist while the wrapper is still
   alive and mid-sequence. Checking PID liveness first avoids that race. Two sub-checks, both
   against the `.pid` sidecar (PID + `forked_at` timestamp, section 1):
   - `kill -0 <pid>` (non-blocking signal probe, never a blocking `wait`). If it fails outright
     (no such process), the PID is dead — go to step 2.
   - If `kill -0` succeeds, that alone only proves *some* process currently holds that PID number —
     not that it's actually this task's wrapper (confirmed live: `kill -0` against an unrelated
     backgrounded `sleep` process also returns success/exit 0 — any live PID passes it, regardless
     of what it's actually running). Corroborate with `ps -p <pid> -o lstart=,command=` and check
     that the reported start time is at/after the sidecar's own `forked_at` timestamp and that the
     command line plausibly matches a `claude -p` invocation for this task. If `kill -0` succeeded
     but this corroboration does NOT match, treat it exactly like "not alive" — something else now
     holds that recycled PID number — and fall through to step 2.
   - If both the liveness probe and the corroboration check pass: **still running** — poll again
     next cycle, regardless of whether `.final.txt` already exists.
2. **Only once the PID is confirmed not alive (or not corroborated as this task's wrapper) does
   `.final.txt`'s presence/absence matter:**
   - **Present** — the wrapper finished cleanly. Run `bin/dispatch-report.py` against it (section 1)
     to get the terminal exit code. Nothing further to poll for this task-id.
   - **Absent** — an ANOMALY: the process is gone but never produced output (crashed, killed
     externally, etc.). Escalate to the human exactly like a stuck task. Never silently retry it,
     and never assume success just because the process is gone.

The batch is closed once every fanned-out task-id's `spawn-sub-sup.sh` process has exited (reaped),
or the batch TTL expires, whichever comes first. Only AFTER that — for the subset of task-ids whose
process exited with code **4** (`SM_READY_UNMERGED`) — does the dispatcher poll
`bin/progress-ledger.py ready --batch-id <batch-id>` to pull their `checked_sha`/
`checker_verdict_path`, needed to build the consolidated hold's entries file (section 6). A task-id
whose process exited 1/2/3 contributes no `ready` row and needs none: its refusal/stuck/parse-failure
reason is relayed to the human straight from `spawn-sub-sup.sh`'s own exit, not sourced from the
ledger.

**New requirement for the external case:** before fanning out, the dispatcher writes a batch
manifest file:
```
.secondmate/dispatch/<batch-id>.batch.json
```
containing the batch-id and the full list of task-ids it is about to launch:
```json
{"batch_id": "<uuid>", "task_ids": ["<task-id-1>", "<task-id-2>", "..."]}
```
An in-session Agent-tool dispatcher can hold "which task-ids are in this batch" in its own
conversation context across the whole batch's lifetime. An external OS process has no equivalent
durable memory — if the dispatcher process itself restarts mid-batch (crash, redeploy, manual
kill), it has nothing but this file to re-derive which task-ids it was waiting on; `progress-ledger
ready --batch-id` can tell it which of those task-ids are *ready*, but only this manifest tells it
which task-ids belong to the batch in the first place.

## 6. One consolidated hold

Unchanged in shape, same as `skills/secondmate/SKILL.md`'s batch dispatch step (g)–(h): write a JSON
entries file, one object per ready task-id —
```json
[{"task_id": "...", "checked_sha": "...", "checker_verdict_path": "..."}, ...]
```
— then:
```bash
bin/hold.py hold --task "<batch-label>" --q "merge which of: <task-id-1>, <task-id-2>, ...?" \
  --entries-file <that JSON file>
```
Wait for a genuine human answer; never self-answer. The answer is structured, not freeform prose,
and must cover every entry in exactly one list:
```bash
bin/hold.py answer <hold-id> --approve "<id>,<id>,..." --reject "<id>,..."
```

**Edge case: zero task-ids reached `SM_READY_UNMERGED` (exit 4).** If every task-id in the batch
ended up refused, stuck, or malformed — none of them reaching ready-unmerged — the entries file
would be `[]`, and `bin/hold.py hold --entries-file` rejects that outright (confirmed by reading
its own entries-file validation and by running it live against an empty-list file: it exits nonzero
with `must contain a non-empty JSON list of entries`, never opening a hold or writing to the
ledger). Do **not** call `hold.py hold` in that case — there is nothing to merge. Instead, relay
every refusal/stuck reason to the human verbatim (ordinary dispatcher discipline, unchanged) and
treat the batch as done: no hold, no merge sequencing, no entries file at all.

## 7. Merge sequencing — one approved task-id at a time

For every APPROVED task-id, in sequence (never in parallel — `merge-sequencer.sh`'s lock is a
mkdir-based singleton at `${SM_LOOP_STATE:-<repo>/.secondmate}/merge-sequencer.lock`, so sequencing
here is about correctness of the follow-on steps, not just lock contention). **This lock only
truly serializes two concurrent dispatchers against the same repo if they agree on the same
`SM_LOOP_STATE` value** (confirmed by reading `merge-sequencer.sh`'s own lock-path resolution
directly) — or both leave it unset, which resolves consistently to `<repo>/.secondmate` for both.
Two dispatcher processes with *different* `SM_LOOP_STATE` values targeting the identical repo get
two separate lock directories and can merge concurrently, defeating the singleton entirely. This is
the same underlying principle as section 8's shared-ledger-path discipline below (a shared
lock/ledger path requires every dispatcher invocation against a given repo to agree on the same
env var) — apply it here too, for `SM_LOOP_STATE` specifically.

```bash
bin/merge-sequencer.sh --repo <repo> --worktree <worktree> --branch "sm/<task-id>" --base main \
  --checked-sha <that entry's checked_sha>
```
**Only on exit 0** does the dispatcher run the follow-on cleanup — never unconditionally:
```bash
herdr worktree remove --workspace <workspace-id>
git branch -d "sm/<task-id>"
bin/claim-ledger.py release --task-id <task-id> --owner "sm-<task-id>" --token <token from section 3>
bin/teardown-check.sh --task-id <task-id>
```
On any **nonzero** `merge-sequencer.sh` exit (e.g. it refuses a stale `--checked-sha`), the
dispatcher leaves the worktree, branch, and claim exactly as they are — do not remove the worktree,
delete the branch, or release the claim — and relays the failure to the human, the same discipline
as a stuck/refused task. Running the cleanup unconditionally discards an unmerged, still-good
task's work and frees its task-id for someone else to claim out from under it.

A **rejected** task-id is left completely untouched: claim still open, worktree and branch still in
place, nothing released. It stays `claimed, needs rework` until a human-driven rework round or an
explicit `--steal` resolves it — never silently released just because the batch moved on.

## 8. Dispatcher discipline

All the discipline rules in `skills/secondmate/SKILL.md` still apply unchanged: never write project
code, never self-answer a hold, full-SHA discipline (never a truncated or re-derived SHA), relay
every refusal/stuck reason to the human verbatim, detection-only watchdogs that never auto-restart
or auto-`--steal`. Two additions apply specifically to the external case:

1. **Run every ledger-touching invocation from the repo root, or export the matching
   `SM_*_LEDGER` env var.** `bin/hold.py` defaults its ledger path to a plain CWD-relative
   `decisions.jsonl` with no fallback at all. `bin/claim-ledger.py` and `bin/progress-ledger.py` are
   smarter — they fall back to `git rev-parse --git-common-dir` so every worktree of the same repo
   agrees on one shared ledger — but that fallback still requires the process's CWD to be inside a
   git checkout of this repo in the first place. An external dispatcher process has no such
   guarantee: a cron job's CWD defaults to the user's home directory, a systemd unit's CWD defaults
   to `/`, and a daemon that `cd`'d somewhere else mid-run can silently resolve a *different*,
   phantom ledger file — invisible to the in-session SessionStart hook and to every other actor
   reading the real one. Always either run from the repo root or export `SM_HOLD_LEDGER` /
   `SM_CLAIM_LEDGER` / `SM_PROGRESS_LEDGER` to the real, absolute path before any `hold.py` /
   `claim-ledger.py` / `progress-ledger.py` call.
2. **Validate before any shell-out, and never hand-assemble a shell string.** A task-id must match
   `[A-Za-z0-9_-]{1,128}` — the same convention `claim-ledger.py`, `hold.py`, `progress-ledger.py`,
   `lesson-lookup.py`, and `teardown-check.sh` already enforce themselves (`claim-ledger.py`'s own
   selfcheck asserts `not _valid_task_id("a" * 129)`, confirming 128 is the real, intentional
   boundary) — and a batch-id must be a UUIDv4. Validate both before using them in any
   path, branch name, or command. Every invocation of `claude`, `git`, or a `bin/` script must be
   called with an argv array (e.g. `subprocess.run([...])`, bash `"${arr[@]}"`), never a string
   handed to a shell `-c` — the same hygiene `claim-ledger.py` and `merge-sequencer.sh` already hold
   themselves to internally, now also required of the dispatcher's own calls into them.

## Proposed secondmate SKILL.md amendment (HUMAN-OWNED — apply by hand)

**Not yet applied.** This is the exact one-to-two sentence addition a human should paste into
`skills/secondmate/SKILL.md`'s own "Dispatch mechanics — solo and batch" section, acknowledging the
external case without touching that file's existing content:

> An external process outside Claude Code (e.g. Hermes, or any agent with terminal access + a
> scheduler) may hold this top-level dispatcher role instead of an in-session Agent-tool caller —
> see `skills/secondmate-dispatch/SKILL.md` for the OS-process spawn/watchdog/hold contract. Every
> sub-agent-supervisor it spawns remains a fresh Claude Code session running this same SOP
> unchanged.
