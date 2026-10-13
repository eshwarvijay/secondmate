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
1. Write a `<task-id>.pid` liveness sidecar into the log dir **before forking** — the OS pid of the
   process about to be spawned. This is independent of `progress-ledger.py`'s self-reported
   checkpoints: it gives the watchdog (section 4) a liveness signal even if the sub-supervisor dies
   before ever recording its first checkpoint.
2. Fork a **brand-new** `claude -p --output-format stream-json` process for that task-id and
   prompt. Never `--continue` or `--resume` — every sub-supervisor must start with zero inherited
   context, the exact same "Agent tool, never fork" discipline `skills/secondmate/SKILL.md` already
   requires for the in-session case, just enforced via process flags instead of a tool-call
   parameter.
3. Tee the raw `stream-json` output to `.secondmate/dispatch/<task-id>.jsonl` as it streams.
4. On process exit, extract the final assistant message's plain-text content out of that
   `stream-json` log into `.secondmate/dispatch/<task-id>.final.txt`.
5. Run `bin/dispatch-report.py` against that `.final.txt` file — **never** the raw `.jsonl`.
   `dispatch-report.py`'s own completion-tag regex is anchored at the start of a line; a completion
   tag that happens to appear inside a JSON string value in the raw stream (e.g. quoted inside a
   `"text": "...SM_DONE_MERGED:abc123..."` field) would never match there, so only the extracted
   plain text is a valid target.
6. Exit with `dispatch-report.py`'s own exit code **verbatim** — never a raw bash `$?` from the
   `claude -p` process itself (that reflects the CLI's own exit status, not the parsed completion
   tag).

**Outputs:** `.secondmate/dispatch/<task-id>.jsonl` (raw), `.secondmate/dispatch/<task-id>.final.txt`
(extracted plain text), `.secondmate/dispatch/<task-id>.pid` (liveness sidecar).

**Exit code:** `dispatch-report.py`'s own exit code (0/1/2/3 — see that script's contract in
`skills/secondmate/SKILL.md`), relayed unchanged.

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
  bin/pane-reaper.py observe
  bin/pane-reaper.py quiet --threshold-seconds "$N" | grep -F -e "\"pane_id\": \"${root_pane_id}\"" ...
  # relay any hit from either call to the human verbatim, exactly as the in-session watchdog does —
  # never restart, never steal, never treat a hit as a confirmed crash
  sleep "$N"
done
```

The loop itself — not any cron/launchd/systemd entry — is the portable unit; it can run under a
plain `nohup`/`tmux` session anywhere. A scheduler entry may optionally backstop it (e.g. checking
that the loop's own heartbeat file has advanced recently and restarting the *loop process* if not),
but that backstop is optional infrastructure around the loop, not a substitute for it.

## 5. Batch close and the batch manifest

Batch close is unchanged — still ledger-driven, never from the dispatcher's own in-memory state:
poll `bin/progress-ledger.py ready --batch-id <batch-id>` until every fanned-out task-id has
reached a terminal `dispatch-report.py` exit code, or the batch TTL expires, then open the
consolidated hold (section 6).

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

## 7. Merge sequencing — one approved task-id at a time

For every APPROVED task-id, in sequence (never in parallel — `merge-sequencer.sh` already
singleton-locks per `--repo`, so sequencing here is about correctness of the follow-on steps, not
just lock contention):
```bash
bin/merge-sequencer.sh --repo <repo> --worktree <worktree> --branch "sm/<task-id>" --base main \
  --checked-sha <that entry's checked_sha>
herdr worktree remove --workspace <workspace-id>
git branch -d "sm/<task-id>"
bin/claim-ledger.py release --task-id <task-id> --owner "sm-<task-id>" --token <token from section 3>
bin/teardown-check.sh --task-id <task-id>
```
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
   `^[a-zA-Z0-9_-]{1,64}$` and a batch-id must be a UUIDv4 — validate both before using them in any
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
