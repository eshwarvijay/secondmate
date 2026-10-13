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

**One process, start to finish — not a wrapper forking a separate child.** An earlier draft of
this contract had `spawn-sub-sup.sh` fork an inner `claude -p` child and sidecar THAT child's PID,
then had the watchdog (section 5) check that same PID to decide whether the *task* was done. That
confuses two different lifetimes: the inner `claude -p` child can exit while `spawn-sub-sup.sh`
itself is still alive doing extraction, running `dispatch-report.py`, and exiting — so watching the
child's PID tells you nothing about whether the task is actually finished. The fix is to collapse
this to one process whose entire lifetime, start to finish, IS the task's liveness: `spawn-sub-sup.sh`
runs `claude -p` **synchronously**, in its own foreground (e.g. piping its output through `tee`
and blocking on it), then does extraction and `dispatch-report.py` itself, then exits with that
code — there is no second, inner process to ever confuse with the one being tracked.

**Invocation (by the dispatcher, backgrounding `spawn-sub-sup.sh` itself):**
```bash
bin/spawn-sub-sup.sh --task-id <task-id> --prompt-file <path> --log-dir .secondmate/dispatch &
echo $! > ".secondmate/dispatch/<task-id>.pid"
```
PID bookkeeping now lives with the **dispatcher**, not inside the script: the dispatcher
backgrounds the one process whose whole lifecycle matters and captures `$!` as its very next
action, immediately after backgrounding it — the same idiom as before, just relocated to the
caller, where it is trivially correct (no "before/after fork" ambiguity, because there is exactly
one thing being forked and exactly one thing being tracked). `$!` is still only available *after*
the `&` backgrounding has actually happened (confirmed live: a probe script printed `$!` as empty
immediately before backgrounding a process, and only non-empty immediately after) — so this
capture is necessarily the dispatcher's next line, never something done beforehand.

**Inputs:** a `--task-id` (validated by the dispatcher before the call — see Discipline below), a
`--prompt-file` holding the full sub-supervisor prompt (claim → SOP → completion tag, same prompt
shape as the Agent-tool version, plus the `SM_CLAIM_TOKEN:` line required below), and a `--log-dir`.

**Behavior, in order (inside `spawn-sub-sup.sh` itself, all synchronous):**
1. Run `claude -p --output-format stream-json` for that task-id and prompt, in the foreground,
   piping its output through `tee` to `.secondmate/dispatch/<task-id>.jsonl` as it streams, and
   **block until that invocation exits.** Never `--continue` or `--resume` — every sub-supervisor
   must start with zero inherited context, the exact same "Agent tool, never fork" discipline
   `skills/secondmate/SKILL.md` already requires for the in-session case, just enforced via process
   flags instead of a tool-call parameter.
2. Once `claude -p` has exited, extract the final assistant message's plain-text content out of
   the `.jsonl` log into `.secondmate/dispatch/<task-id>.final.txt`.
3. Run `bin/dispatch-report.py` against that `.final.txt` file — **never** the raw `.jsonl`.
   `dispatch-report.py`'s own completion-tag regex is anchored at the start of a line; a completion
   tag that happens to appear inside a JSON string value in the raw stream (e.g. quoted inside a
   `"text": "...SM_DONE_MERGED:abc123..."` field) would never match there, so only the extracted
   plain text is a valid target.
4. Exit with `dispatch-report.py`'s own exit code **verbatim** — never a raw bash `$?` from the
   `claude -p` process itself (that reflects the CLI's own exit status, not the parsed completion
   tag). This is also the exit code the dispatcher's own `kill -0`/reap sees (section 5), since
   steps 1–4 all run inside the one PID it is tracking.

**Outputs:** `.secondmate/dispatch/<task-id>.jsonl` (raw) and `.secondmate/dispatch/<task-id>.final.txt`
(extracted plain text), both written by `spawn-sub-sup.sh` itself. `.secondmate/dispatch/<task-id>.pid`
(liveness sidecar) is written by the **dispatcher**, not by `spawn-sub-sup.sh` — see the invocation
recipe above.

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

Every spawned sub-supervisor leaves exactly three artifacts under `.secondmate/dispatch/`:
- `<task-id>.jsonl` — the raw `stream-json` transcript, written by `spawn-sub-sup.sh` itself,
  append-only, useful for a human reading back what actually happened.
- `<task-id>.final.txt` — the extracted plain-text content of the final assistant message only,
  also written by `spawn-sub-sup.sh` itself. This is the ONLY file the dispatcher parses
  programmatically — both for `dispatch-report.py` (section 1) and for the claim-token line
  (section 3).
- `<task-id>.pid` — the liveness sidecar, written by the **dispatcher** (not `spawn-sub-sup.sh`)
  immediately after backgrounding it (section 1). Used by the watchdog's reap check (section 5).

## 3. Extracting the claim token

**This procedure applies only to a task-id whose `dispatch-report.py` exit code turns out to be
`4` (`SM_READY_UNMERGED`) — check the exit code FIRST, before doing anything in this section.**
Per `skills/secondmate/SKILL.md`'s own batch protocol, a sub-supervisor releases its OWN claim
internally before emitting `SM_REFUSED` or `SM_STUCK_NEED_HUMAN` if it had successfully claimed,
and `SM_REFUSED:claim-failed` specifically means the claim never succeeded in the first place
(confirmed by reading that file directly: step (a) aborts with `SM_REFUSED:claim-failed` on a
failed claim, before any token could exist; step (d) says a refusal/stuck path "behave[s] exactly
as solo dispatch does: release the claim and emit `SM_REFUSED:<reason>` or
`SM_STUCK_NEED_HUMAN:<reason>`" — i.e. it self-releases). Only on exit `4` does the sub-supervisor
deliberately leave its claim open for the external dispatcher to release later (section 7) — every
other exit code (`0`/`1`/`2`/`3`) means there is either nothing to release or it was already
released internally, and this section's token requirement never applies to it. Treating a
legitimate `SM_REFUSED:claim-failed` as if it needed a token — the earlier draft of this
section did, since it ran this whole procedure unconditionally — would misroute an ordinary,
expected refusal into "stuck, needs a token," contradicting the parent SOP it's supposed to
mirror. For exit codes other than `4`, skip this section entirely: relay the refusal/stuck/done
outcome exactly as sections 5 and 8 already document, with no claim-token involvement at all.

For a task-id that DID exit `4`: the sub-supervisor claims its task-id inside its own fresh
process (`bin/claim-ledger.py claim --task-id <id> --owner sm-<id>`), which prints `token=<hex>` to
that process's own stdout — but the external dispatcher never sees that process's live stdout,
only the extracted `.final.txt`. So every sub-supervisor's prompt must require it to emit
**exactly one** dedicated line in its final output:
```
SM_CLAIM_TOKEN:<the hex token claim-ledger.py printed>
```
This is a **separate** line from the completion tag — `dispatch-report.py`'s own tag regex only
recognizes `SM_DONE_MERGED` / `SM_REFUSED` / `SM_STUCK_NEED_HUMAN` / `SM_READY_UNMERGED` and does
not look for `SM_CLAIM_TOKEN:` at all, and critically, `SM_CLAIM_TOKEN:` carries no "must be the
literal final line" requirement the way the completion tag does — it can legitimately appear
anywhere in the final text. That means picking `head -1` or `tail -1` here is **guessing, not
protocol enforcement**: `dispatch-report.py`'s own "last line wins" rule for ITS tags works only
because that protocol *requires* the real tag to be the literal final output line, a guarantee
`SM_CLAIM_TOKEN:` was never given. If the sub-supervisor's final text happens to contain two
syntactically valid `SM_CLAIM_TOKEN:`-shaped lines (e.g. the real one plus an unrelated-but-
valid-looking echoed example), blindly taking either the first or the last can silently grab the
WRONG one — and releasing the claim with a wrong token fails, leaving a successfully merged
task's claim stuck open forever with no further signal that anything went wrong.

So the dispatcher does not guess between head/tail at all. It counts the matching lines in
`.final.txt` FIRST, directly off `grep`'s own line count — never through a value-bearing
intermediate variable — and only extracts a value once that count is confirmed to be exactly 1:
```bash
n=$(grep -c '^SM_CLAIM_TOKEN:' ".secondmate/dispatch/${task_id}.final.txt" || true)
if [ "$n" -eq 1 ]; then
  token=$(grep '^SM_CLAIM_TOKEN:' ".secondmate/dispatch/${task_id}.final.txt" | cut -d: -f2-)
fi
```
Two mechanical shell-correctness details, both load-bearing, both live-verified:
- **The `|| true` on the counting `grep -c` is required**, not decorative. Under a normal strict
  shell (`set -euo pipefail`, which a real dispatcher script should run under), `grep` exits 1 on
  zero matches; with `pipefail` that fails the whole assignment and `set -e` then aborts the
  script *before* it ever reaches the "zero matches → escalate" branch below. Confirmed live: the
  unguarded form (`n=$(grep -c ... )`, no `|| true`) under `set -euo pipefail` against a file with
  zero matching lines killed the script outright (exit 1, no further output) — the escalation
  logic was never reached. With `|| true`, the same zero-match case instead correctly assigns
  `n=0` and the script continues.
- **Counting must happen on `grep`'s own match lines, never on a `cut`-derived, `$()`-captured
  value.** An earlier draft counted `cut -d: -f2-`'s *output* via `printf '%s\n' "$tokens" | grep
  -c .` — this undercounts whenever one of the matching lines has an EMPTY value after the colon
  (e.g. a malformed `SM_CLAIM_TOKEN:` with nothing after it): `cut`'s output for that line is an
  empty string, and command substitution (`$(...)`) strips ALL trailing newlines from its captured
  value, so a trailing empty line silently vanishes from `$tokens` before it's ever counted.
  Confirmed live: two real matching lines (`SM_CLAIM_TOKEN:abc123` and a second, empty-valued
  `SM_CLAIM_TOKEN:`) counted as `n=1` through the old path, not 2 — the multiple-line escalation
  never triggered, and the (wrong, since ambiguous) sole surviving token got used. Counting
  `grep -c`'s own matched LINES directly, before any `cut`, has no such information loss and
  correctly reported `n=2` for the identical input.

Then branch on `n`:
- **`n` is exactly 1** — **validate the extracted value's shape before using it, do not just
  trust `n == 1`.** A single matching line can still have an EMPTY value after the colon (e.g. a
  malformed or truncated final text) — `n == 1` alone does not mean the extracted string is a real
  token. Confirmed live: a `.final.txt` with exactly one `SM_CLAIM_TOKEN:` line and nothing after
  the colon counts as `n=1`, and the old recipe would proceed straight to using that empty string
  as if it were real. Real tokens are always `secrets.token_hex(16)` — a 32-character lowercase
  hex string (confirmed by reading `claim-ledger.py`'s own `_TOKEN_RE = re.compile(r"\A[0-9a-f]
  {32}\Z")` directly). So validate: `[[ "$token" =~ ^[0-9a-f]{32}$ ]]`. If it matches, use it —
  this is the well-behaved case. If it does NOT match (confirmed live against the empty-value
  case above), treat it exactly like the "zero or more than one" case below — never call
  `bin/claim-ledger.py release` with a value that was never confirmed to be a real token.
- **`n` is 0 or more than 1 — or `n` is 1 but the extracted value fails shape validation** — a
  protocol violation for this task-id. Do NOT guess which one (if any) is real; do not even
  attempt to use it. Treat it exactly like a stuck task: escalate to the human verbatim (which
  task-id, and the actual value of `n` or the malformed token string), the same "don't guess when
  ambiguous" posture `dispatch-report.py` itself takes for a missing completion tag (its own exit
  3, `malformed`). This is the safety net, not the primary mechanism — the primary mechanism is
  the prompt-contract requirement above: a well-behaved sub-supervisor emitting exactly one
  `SM_CLAIM_TOKEN:` line never triggers this path in the first place.

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
  bin/progress-ledger.py stale --threshold-seconds "$N" "${task_id_flags[@]}" || true
  # the .pid sidecar liveness check (section 1/5) is the ALWAYS-available signal, no herdr required —
  # poll it here too, non-blocking (kill -0), for any task-id whose .final.txt hasn't appeared yet
  if command -v herdr >/dev/null 2>&1; then
    bin/pane-reaper.py observe || true
    bin/pane-reaper.py quiet --threshold-seconds "$N" | grep -F -e "\"pane_id\": \"${root_pane_id}\"" ... || true
  fi
  # relay any hit from either call to the human verbatim, exactly as the in-session watchdog does —
  # never restart, never steal, never treat a hit as a confirmed crash
  sleep "$N"
done
```

**Both `|| true` guards are required under `set -e`, not decorative — a strict-mode loop must
survive its own documented "normal" outcomes, not just its errors.** `bin/progress-ledger.py
stale` exits `1` precisely when it finds a real stale/no-progress hit (confirmed by reading its
own `stale` command directly: `sys.exit(1 if hits else 0)`) — that nonzero exit is the exact
signal this watchdog exists to catch, not an error condition. Confirmed live: the unguarded call,
under `set -euo pipefail`, aborted the loop body the moment it found a genuine stale hit — the
watchdog would die on its own success case and never loop again. The `pane-reaper.py quiet | grep`
line has the identical problem from the opposite direction: `grep` exits 1 whenever nothing
currently matches the filter (the common, expected "nothing quiet right now" case), and under
`pipefail` that kills the loop too — confirmed live against a filter with zero matches. Both `||
true` guards let the loop survive either outcome and continue relaying whatever each call printed
to stdout before `sleep`-ing and polling again; live-ran the fixed loop body across 3 iterations
with a real recurring stale hit each time — it completed all 3 without aborting.

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

1. **Is the `.pid` sidecar's recorded PID still alive — distinguishing a truly running process
   from a zombie, which a bare `kill -0` cannot do?** `.final.txt`'s mere presence does NOT prove
   the process has finished: per section 1's own step order, `spawn-sub-sup.sh` writes
   `.final.txt` at step 2, then still has to run `dispatch-report.py` (step 3) and exit with its
   code (step 4) — so `.final.txt` can exist while the tracked PID is still alive and mid-sequence.
   Checking liveness first avoids that race — but liveness itself needs more care than a bare
   `kill -0`: a child that has already exited but was never reaped by its parent becomes a ZOMBIE
   (defunct), and `kill -0` on a zombie's PID still succeeds — the kernel has not yet recycled that
   PID slot — so a check built on `kill -0` alone would classify a zombie as "still running" and
   poll forever, and the batch would never close. Confirmed live: forked a child that exits
   immediately but was deliberately left unreaped — `ps -o stat=,command= -p <pid>` reported
   `Z    <defunct>` while `kill -0 <pid>` on that same PID still returned success (exit 0).

   So the check is `ps -o stat= -p <pid>` (portable across Linux and macOS/BSD), not `kill -0`
   alone — **and the `ps` call itself must be guarded under strict mode**: `ps -o stat= -p <pid>`
   on a dead PID exits nonzero (confirmed live: exit 1 against a PID that no longer exists), and
   under `set -e` the bare assignment `state=$(ps ...)` would abort the whole poll before it ever
   reaches the "`$state` is empty → not alive" branch below — the exact routine, expected case
   this check exists to classify. So:
   ```bash
   state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
   ```
   - **`$state` is empty** (no such PID at all) — not alive — go to step 2.
   - **`$state` starts with `Z`** (zombie/defunct) — also not alive for the purpose of this check
     — go to step 2. If this poll is running inside the SAME dispatcher process that originally
     forked `spawn-sub-sup.sh` (not a restarted dispatcher — see the restart-safety note just
     above), additionally reap the zombie and free its process-table slot — but capture `wait`'s
     own return value rather than letting it propagate as a command failure:
     ```bash
     rc=0
     wait "$pid" 2>/dev/null || rc=$?
     ```
     This capture is required, not optional: `wait "$pid"` returns the REAPED CHILD's own exit
     status (e.g. `4` for `SM_READY_UNMERGED`), and under `set -e` a bare `wait "$pid"` call with
     no `||` treats that nonzero status as `wait` itself failing — aborting the poll instead of
     treating `$rc` as `spawn-sub-sup.sh`'s terminal dispatch-report code and continuing (confirmed
     live: a bare `wait "$pid"` on a child that exited `4` killed the whole script with exit `4`,
     never reaching code after it; capturing via `rc=0; wait "$pid" || rc=$?` instead correctly
     recorded `rc=4` and let the script continue). `waitpid()` itself still returns immediately
     (0.000s, confirmed live) for an already-exited child — it only blocks for a genuinely
     still-running child, which is not this branch. A restarted dispatcher cannot `wait` on a PID
     it never forked and does not need to: once the original parent process is truly gone, the
     kernel reparents any zombie it left behind to init/launchd, which reaps it on its own — the
     "not alive" classification above is already correct regardless of who, if anyone, performs
     the explicit reap.
   - **`$state` is any other, non-empty, non-`Z` value** (a real running state) — still running;
     poll again next cycle, regardless of whether `.final.txt` already exists.

   **Accepted limitation, not solved here:** this `ps`-based check is still a best-effort liveness
   signal — it only proves *some* process currently holds that PID number in a real running state,
   not that it is still `spawn-sub-sup.sh` (confirmed live: a plain liveness probe against an
   unrelated backgrounded process also returns "alive" — any live PID passes it, regardless of
   what it's actually running). In the rare case the OS reuses that exact PID for an unrelated
   process in the narrow window between the real process exiting and the next watchdog poll, this
   check would false-positive "still alive." This is the same single-operator, local-git trust
   model the parent skill already accepts elsewhere ("detection only, no automated certainty") —
   this contract does not try to eliminate that narrow race with a more elaborate corroboration
   scheme; it accepts it as a known, bounded limitation.
2. **Once the PID is confirmed not alive, `.final.txt`'s presence/absence decides the outcome:**
   - **Present** — the process finished cleanly. Run `bin/dispatch-report.py` against it (section 1)
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

Same shape as `skills/secondmate/SKILL.md`'s batch dispatch step (g)–(h): write a JSON entries
file, one object per ready task-id —
```json
[{"task_id": "...", "checked_sha": "...", "checker_verdict_path": "..."}, ...]
```

**Restart-safe: check for an already-open hold before opening a new one.** If the dispatcher
crashes after opening this batch's hold but before a human answers it, a naively-restarted
dispatcher that just re-ran the recipe below would call `hold.py hold` again and open a SECOND,
duplicate hold for the same batch (confirmed live: running the identical `hold.py hold
--entries-file ...` call twice in a row produced two distinct open hold ids, both still open).
So, before opening a hold, check whether one already exists for this batch — guarded, since the
ordinary "no open hold yet" case (the normal first-batch-close path, not an error) still has to
survive under strict mode:
```bash
existing_id=$(bin/hold.py open | grep -F "(<batch-label>)" | head -1 | sed -E 's/^\[([^]]+)\].*/\1/' || true)
```
The `|| true` is required, not decorative: when there is genuinely no open hold at all (the
ordinary case right after a batch's first close), `grep` finds no match and exits 1, and under
`set -o pipefail` that failure propagates through the whole pipeline even though `hold.py open`
itself exits 0 for "no open decisions" — confirmed live: the unguarded pipeline, under
`set -euo pipefail` with zero open holds, aborted the script (exit 1) before the dispatcher ever
reached "open a new hold." With `|| true`, the identical zero-match case instead correctly leaves
`existing_id` empty and the script continues to the branch below.

`hold.py open`'s own output format is `[<id>] (<task>) <question>` per open hold (confirmed by
reading its `open` command source directly, and by running it live: it printed exactly
`[dcfa5ec7] (batch-abc123) merge which of: t1?`), so matching on `(<batch-label>)` finds any open
hold whose `task` field is this batch's own `--task` string.
- **A matching open hold is found** (`$existing_id` is non-empty) — reuse its id; do NOT call
  `hold.py hold` again. Just keep waiting for a human to answer that existing hold.
- **No matching open hold is found** (`$existing_id` is empty) — only then open a new one:
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
if command -v herdr >/dev/null 2>&1; then
  herdr worktree remove --workspace <workspace-id>
else
  git -C <repo> worktree remove <worktree>
fi
git branch -d "sm/<task-id>"
bin/claim-ledger.py release --task-id <task-id> --owner "sm-<task-id>" --token <token from section 3>
bin/teardown-check.sh --task-id <task-id>
```
**Guard `herdr worktree remove` the same way section 4 already guards `pane-reaper.py`:** this
dispatcher's own Scope section only requires "terminal access + a scheduler" — herdr is optional,
not a hard dependency. Running `herdr worktree remove` with no `herdr` binary on `PATH` fails with
`command not found` and exit 127 (confirmed live), leaving the worktree behind with no further
signal that cleanup silently failed. The headless/no-herdr fallback is plain `git -C <repo>
worktree remove <worktree>` — the same plain-git worktree operation the parent skill's own
headless path already uses to CREATE a worktree (`bin/new-worktree.sh`'s own `git -C "$repo"
worktree add -b "$branch" "$wt" "$base"`, confirmed by reading that script directly); removal just
mirrors creation.
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
