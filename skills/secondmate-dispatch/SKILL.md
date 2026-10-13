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

## Strict-mode exit-code discipline (read this before any shell recipe below)

Every recipe below assumes the dispatcher runs under `set -euo pipefail` — correct discipline for
a strict external process, where a mistake should fail loudly rather than silently continuing on
bad data. But three consecutive review rounds on this file found the SAME two bug classes
recurring in a new location each time: **(A)** a command's own real contract includes a
*documented, expected* nonzero exit for a normal outcome (e.g. `dispatch-report.py` exits `4` for
`SM_READY_UNMERGED`, the single most common terminal state) — a bare, uncaptured call under
`set -e` treats that nonzero exit as the command itself failing and kills the dispatcher before it
ever acts on the result; and **(B)** a fix for (A) that over-corrects into a blanket `|| true` —
which then ALSO swallows a genuinely unexpected failure (a missing binary, a permissions problem, a
corrupted file, an unrelated tool crash) by treating every nonzero exit as identical to the
documented normal one.

**One idiom closes both classes, applied everywhere below:** capture the real exit code
explicitly, then classify it against — and ONLY against — that specific command's own real,
observed contract at this call site. Anything outside that known set is NOT reinterpreted as the
nearest documented outcome; it escalates to the human verbatim, citing the actual command and the
actual exit code.

```bash
rc=0
<command> || rc=$?
case "$rc" in
  <code-1>|<code-2>|...) : branch on $rc exactly as documented below for this command ;;
  *) : UNEXPECTED — escalate to the human verbatim (command + "$rc"); never treat as any
       documented outcome, never silently continue ;;
esac
```

Never `|| true` on a bare command — that discards `$rc` entirely, which is exactly what collapses
classes (A) and (B) into each other. Capture first, decide second.

**Each tool's own real contract, read directly from source/tests, not assumed:**
- `bin/dispatch-report.py <final.txt>` — `{0,1,2,3,4}` (`SM_DONE_MERGED` / `SM_REFUSED` /
  `SM_STUCK_NEED_HUMAN` / malformed / `SM_READY_UNMERGED`). Confirmed live: calling it against a
  file that does not exist raises an unhandled `FileNotFoundError` and ALSO exits `1` — the SAME
  code as a legitimate `SM_REFUSED`. Mitigation: never call it without first confirming the target
  file exists via an explicit `[ -f ... ]` test (see section 5) — that test, not the exit code
  alone, is what rules out the file-missing case.
- `bin/merge-sequencer.sh` — `{0,1,2,3,4,5}` for a normal (non-`--preflight-only`) invocation: `0`
  success, `1` gate refusal/`BRANCH_MISMATCH`, `2` usage error, `3` merge conflict/rejection, `4`
  push failed, `5` lock timeout (confirmed by reading its own header doc comment and test-fixture
  assertions directly; codes `6`–`8` exist only for `--preflight-only`, never used by this
  dispatcher). Anything outside `0`–`5` here is genuinely unexpected (e.g. `126`/`127` if the
  script itself can't even run).
- `bin/hold.py open` — binary: `0` success (even with zero open holds), any nonzero is a genuine
  failure (confirmed live: a directory-backed ledger path raises an unhandled `IsADirectoryError`
  and exits `1`). No in-between "documented failure" case to classify — any nonzero escalates.
- `bin/progress-ledger.py stale` — `{0,1}`: `0` no hits, `1` a real stale/no-progress hit (the
  exact signal this check exists to produce — confirmed by reading `sys.exit(1 if hits else 0)`
  directly). A dispatcher-supplied `--threshold-seconds` is always numeric and under the
  dispatcher's own control, so argparse's usage-error exit `2` should never occur in practice; if
  it ever does, that is still outside `{0,1}` and must escalate, not be swallowed.
- `bin/pane-reaper.py observe` — `{0}`: `0` success, `2` is `ERR_HERDR` (confirmed by reading
  `ERR_HERDR = 2` directly, with its own source comment: "a tooling outage must never look like
  'clean'"). This call site is already gated behind `command -v herdr`, so an `ERR_HERDR` here
  means herdr was present at the gate but the actual call still failed — a real tooling outage,
  not the "herdr absent" case that gate already handles. Any nonzero here escalates.
- `bin/pane-reaper.py quiet` — `{0,1}`: `0` nothing quiet, `1` a real quiet-pane hit (confirmed by
  reading `find_quiet`'s own hit construction and the command's `sys.exit(1 if hits else 0)`
  directly).
- `ps -o stat= -p <pid>` — `{0,1}`: `0` found (state printed), `1` no such process (empty stdout).
  Confirmed live that this exit/output signature is IDENTICAL whether the PID is a genuinely dead
  (but well-formed) process or the sidecar content is not a PID at all (e.g. `"not-a-pid"`, or even
  `"0"` — never a valid spawnable child PID) — `ps` cannot tell these apart, so the PID-sidecar's
  own content must be validated as `^[1-9][0-9]*$` (a positive integer, not merely digits-only)
  BEFORE ever calling `ps` on it (see section 5). Confirmed live separately: a missing `ps` binary
  on `PATH` exits `127`, outside `{0,1}` — genuinely unexpected, must escalate.
- `grep` (any form used in this file) — `{0,1}` is the normal "match found / no match" contract;
  `2` is a real error (confirmed live: a missing or unreadable target file exits `2` with a message
  on stderr, distinct from the "zero matches" exit `1`). When `grep` reads from a pipe or an
  in-memory string (never a filename argument), a file-not-found error is structurally impossible,
  so `{0,1}` is the complete set at that call site and a plain `|| true` is honestly sufficient
  there — see each site below for which case applies.
- `wait "$pid"` — when `$pid` is genuinely this shell's own child and has already exited, `wait`
  returns THAT CHILD'S OWN exit code verbatim (for `spawn-sub-sup.sh`, that means `{0,1,2,3,4}`,
  the same set as `dispatch-report.py` above, since steps 1–4 of section 1's contract all run
  inside the one PID being `wait`ed on). `wait` returns `127` if `$pid` was never this shell's own
  child, and (confirmed live) a shell-specific message plus a nonzero code if `$pid` isn't even a
  well-formed PID — both outside `{0,1,2,3,4}`, both mitigated the same way: validate PID format
  before calling `wait`, exactly as for `ps`.

Live-verified all of the above in one consolidated probe before writing this section: each tool's
documented-normal case correctly continued past the capture-and-classify idiom, and each
genuinely-unexpected case (file-missing, malformed PID content, `ps`/herdr binary absent,
directory-backed ledger) was correctly routed to escalation instead of being silently reinterpreted
as the nearest normal outcome.

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
   tag). This is also the exit code the dispatcher's own `ps -o stat=`-based liveness check and
   `wait`-based reap see (section 5), since steps 1–4 all run inside the one PID it is tracking.

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

So the dispatcher does not guess between head/tail at all, and does not pipe through a second
external tool to extract the value either. ONE `grep` call captures the matching lines' raw
content; both the count and the extraction are then pure bash — no `cut`, no `sed`, no second
process, and no second exit code to classify (`grep` here reads a real FILE, not a pipe or an
in-memory string, so its full `{0,1,2}` contract applies and a genuine file-read failure, exit `2`,
must be told apart from "zero matches," exit `1`):
```bash
rc_g=0
matched=$(grep '^SM_CLAIM_TOKEN:' ".secondmate/dispatch/${task_id}.final.txt") || rc_g=$?
if [ "$rc_g" -ne 0 ] && [ "$rc_g" -ne 1 ]; then
  : # ESCALATE to the human verbatim (task-id, "$rc_g") -- e.g. exit 2, the file vanished or became
    # unreadable; NEVER silently treated as "zero matches"
elif [ "$rc_g" -eq 1 ]; then
  n=0  # grep's documented "zero matches" exit -- n legitimately 0, $matched is empty
else
  newlines="${matched//[^$'\n']/}"   # strip everything except newline characters
  n=$(( ${#newlines} + 1 ))          # line count = internal-newline count + 1
  if [ "$n" -eq 1 ]; then
    token="${matched#SM_CLAIM_TOKEN:}"   # strip the known prefix -- pure bash, no external tool
  fi
fi
```
Three mechanical shell-correctness details, all load-bearing, all live-verified:
- **`grep`'s own exit code must be captured and classified, never blanket `|| true`.** Under a
  normal strict shell (`set -euo pipefail`, which a real dispatcher script should run under),
  `grep` exits `1` on zero matches; with `pipefail` that fails the whole assignment and `set -e`
  then aborts the script *before* it ever reaches the "zero matches → escalate" branch below if
  left completely unguarded — confirmed live. But a blanket `|| true` goes too far the other
  direction: it ALSO swallows `grep`'s genuine error exit `2` (the target `.final.txt` vanishing or
  becoming unreadable between when `dispatch-report.py` read it and when this grep runs),
  silently misreporting a real I/O problem as "zero `SM_CLAIM_TOKEN:` lines found." The capture
  above distinguishes `rc_g == 1` (legitimately `n=0`) from any other nonzero (escalate, never
  treated as `n=0`).
- **Counting must happen on `grep`'s own RAW matched lines, never on a `cut`-derived,
  `$()`-captured value — eliminating `cut` is what makes this safe, not another classification
  branch for it.** An earlier draft counted `cut -d: -f2-`'s *output* via `printf '%s\n' "$tokens"
  | grep -c .` — this undercounts whenever one of the matching lines has an EMPTY value after the
  colon (e.g. a malformed `SM_CLAIM_TOKEN:` with nothing after it): `cut`'s output for that line is
  an empty string, and command substitution (`$(...)`) strips ALL trailing newlines from its
  captured value, so a trailing empty line silently vanishes before it's ever counted. The fix
  here isn't a smarter count of `cut`'s output — it's never running `cut` at all: `$matched` holds
  `grep`'s own RAW lines (e.g. `SM_CLAIM_TOKEN:abc123` and, for the empty-valued case,
  `SM_CLAIM_TOKEN:` itself — neither of which is an empty STRING, just a short one), so counting
  the internal newline characters directly in `$matched` via `${matched//[^$'\n']/}` has no such
  information loss. Confirmed live: two real matching lines (`SM_CLAIM_TOKEN:abc123` and a second,
  empty-valued `SM_CLAIM_TOKEN:`) correctly counted as `n=2` through this path.
- **Extraction is `${matched#SM_CLAIM_TOKEN:}` — bash's own prefix-stripping parameter expansion —
  never a second `grep | cut` pipeline.** Once `n == 1` is confirmed, `$matched` already holds
  that single matching line in full; stripping the known, fixed `SM_CLAIM_TOKEN:` prefix is a
  one-line bash builtin with no process to spawn and no exit code to ever go wrong. Confirmed
  live: extracted `0dbc8e60868590c9731bf171f37826a7` correctly from a real matching line this way.

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
  rc_stale=0
  bin/progress-ledger.py stale --threshold-seconds "$N" "${task_id_flags[@]}" || rc_stale=$?
  if [ "$rc_stale" -ne 0 ] && [ "$rc_stale" -ne 1 ]; then
    : # ESCALATE: an exit code outside stale's own documented {0,1} -- e.g. a dispatcher-own usage
      # bug (bad --threshold-seconds). Never treated as "0 hits."
  fi
  # the .pid sidecar liveness check (section 5's zombie-aware `ps -o stat=` check, NOT a bare
  # `kill -0` -- kill -0 cannot tell a zombie from a running process, the exact bug rounds 9-10
  # already fixed in section 5) is the ALWAYS-available signal, no herdr required -- poll it here
  # too, non-blocking, reusing section 5's check verbatim, for any task-id whose .final.txt hasn't
  # appeared yet
  if command -v herdr >/dev/null 2>&1; then
    rc_obs=0
    bin/pane-reaper.py observe || rc_obs=$?
    if [ "$rc_obs" -ne 0 ]; then
      : # ESCALATE: observe's only documented success is 0 -- a nonzero here (including ERR_HERDR=2)
        # past the `command -v herdr` gate above means a REAL tooling outage, not "herdr absent."
    fi
    rc_quiet=0
    quiet_output=$(bin/pane-reaper.py quiet --threshold-seconds "$N") || rc_quiet=$?
    if [ "$rc_quiet" -ne 0 ] && [ "$rc_quiet" -ne 1 ]; then
      : # ESCALATE: outside quiet's own documented {0,1}
    else
      printf '%s\n' "$quiet_output" | grep -F -e "\"pane_id\": \"${root_pane_id}\"" || true
      # the `|| true` here is honestly sufficient (no fix needed): this grep reads a captured
      # STRING via printf, never a filename argument, so its real {0,1,2} contract collapses to
      # {0,1} at this call site -- a "file not found" exit 2 is structurally impossible here.
    fi
  fi
  # relay any hit/escalation from any of the three calls above to the human verbatim, exactly as
  # the in-session watchdog does — never restart, never steal, never treat a hit as a confirmed crash
  sleep "$N"
done
```

**Every example invocation here must be a complete, directly-runnable command — no literal "..."
left sitting where a real argument belongs.** A trailing `...` after the `grep -F -e PATTERN` call
above is not a harmless placeholder: `grep` reads it as an actual extra argv token, and
`grep -F -e PATTERN <extra-arg>` interprets that extra token as a FILENAME to read instead of
stdin — so a real quiet-pane hit arriving on stdin never gets matched, `grep` fails on the missing
file, and the trailing `|| true` silently swallows a hit that should have been relayed to the
human. Confirmed live: piping a real `pane-reaper.py quiet`-shaped JSON line (built from reading
`find_quiet`'s own hit-dict construction directly:
`{"pane_id": pane_id, "status": "quiet", ...}`) into the literal `grep -F -e "..." ...` form
produced `grep: ...: No such file or directory` and exit 2 — the hit was never seen. Removing the
trailing `...` (shown fixed above) against the identical sample line matches correctly (exit 0,
the JSON line printed through).

**If watching more than one pane id, repeat `-e` with the real second pattern, never a
placeholder** — against the SAME already-captured `$quiet_output` from the loop above, never a
second direct re-invocation of `pane-reaper.py quiet`:
```bash
printf '%s\n' "$quiet_output" \
  | grep -F -e "\"pane_id\": \"${root_pane_id}\"" -e "\"pane_id\": \"${checker_pane_id}\"" || true
```
Confirmed live against three sample lines (`root_pane_id`, `checker_pane_id`, and an unrelated
third pane id): this two-`-e` form matched both the root and checker pane lines and correctly
excluded the unrelated one.

**All three calls in the loop body apply the capture-and-classify idiom from "Strict-mode
exit-code discipline" above, not a blanket `|| true`.** `bin/progress-ledger.py stale` exits `1`
precisely when it finds a real stale/no-progress hit (confirmed by reading its own `stale` command
directly: `sys.exit(1 if hits else 0)`) — that nonzero exit is the exact signal this watchdog
exists to catch, not an error condition, so `{0,1}` are both normal and `rc_stale` is only
escalated outside that set. Confirmed live: an unguarded bare call under `set -euo pipefail`
aborted the loop body the moment it found a genuine stale hit — the watchdog would die on its own
success case and never loop again — while the capture-and-classify form above survives it and
keeps looping (live-ran across 3 iterations with a real recurring stale hit each time; completed
all 3 without aborting). `bin/pane-reaper.py observe` is captured the same way, but its own
contract has no "designed normal nonzero" at all once past the `command -v herdr` gate — ANY
nonzero there (including a genuine `ERR_HERDR=2` tooling outage) escalates, which is why a blanket
`|| true` on `observe` was itself a bug: it silently discarded exactly the outage its own source
comment says must never look clean (confirmed live: `observe` with no `herdr` binary on `PATH`
exits `2`, which the old blanket guard swallowed entirely). `pane-reaper.py quiet` is captured into
`$quiet_output` BEFORE any `grep` runs on it, for the identical reason section 6 already
established for `hold.py open`: collapsing `quiet`'s own exit code and the downstream `grep`'s
exit code into one blanket guard over the whole pipe cannot tell "quiet legitimately found nothing
AND grep found nothing" apart from "quiet itself failed." Only the final `grep` stage, reading the
already-captured `$quiet_output` string (never a filename), keeps its plain `|| true` — confirmed
safe per the idiom table above, since a string-input `grep -F` can only return `{0,1}`, never the
file-not-found `2`.

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

   **Before any of that, validate the sidecar's own content is actually a PID — a positive
   integer, not just digits-only — BEFORE ever calling `ps` on it.** `ps -o stat= -p <pid>` returns
   the IDENTICAL signature (exit `1`, empty stdout) for "this well-formed PID doesn't exist" and
   for "this content isn't a PID at all" (confirmed live: `ps -o stat= -p "not-a-pid"` and
   `ps -o stat= -p 88888` — a genuinely dead, well-formed PID — both gave `rc_ps=1` and empty
   `$state`, byte-for-byte indistinguishable). A corrupted or truncated `.pid` sidecar (partial
   write, disk issue, a bug elsewhere writing the wrong thing) must never be silently treated as
   "the task's process legitimately finished" — that is a DIFFERENT, more serious anomaly than a
   normal exit. `^[0-9]+$` (digits-only) is not tight enough: it still accepts `"0"`, which is
   never a valid spawnable child PID (PID 0 has special kernel meaning and is never what `$!`
   returns for a real forked process) — confirmed live, `"0"` matches `^[0-9]+$` just as readily as
   a genuine PID does. The real validation is `^[1-9][0-9]*$` — a positive integer, no leading
   zero, and never literal `0`:
   ```bash
   sidecar_pid=$(cat ".secondmate/dispatch/${task_id}.pid" 2>/dev/null)
   if ! [[ "$sidecar_pid" =~ ^[1-9][0-9]*$ ]]; then
     : # ESCALATE: corrupted/malformed .pid sidecar (incl. literal "0") — never call ps on this,
       # never treat as "not alive"
   else
     pid="$sidecar_pid"
     # proceed to the ps-based liveness check below
   fi
   ```
   Confirmed live: `"0"`, a leading-zero string (`"007"`), and `"not-a-pid"` are all correctly
   rejected by `^[1-9][0-9]*$`, while a genuine PID (`"88888"`) is correctly accepted. Only once
   `$pid` is confirmed to be a well-formed positive integer does the check below run.

   So the check is `ps -o stat= -p <pid>` (portable across Linux and macOS/BSD), not `kill -0`
   alone — **and the `ps` call itself must be guarded under strict mode, but a blanket `|| true`
   is itself a bug**: a blanket guard reclassifies ANY `ps` failure — a dead PID, but also a
   genuinely unexpected one (a missing `ps` binary, a permissions problem, any other system
   error) — as the identical "not alive" outcome, so a still-possibly-running sub-supervisor could
   get silently treated as done just because `ps` itself malfunctioned. The fix captures `ps`'s
   own exit code explicitly and only treats its ONE documented "no such process" signature as
   not-alive — using the general idiom from "Strict-mode exit-code discipline" above, applied to
   `ps`'s own real `{0,1}` contract:
   ```bash
   rc_ps=0
   state=$(ps -o stat= -p "$pid" 2>/dev/null) || rc_ps=$?
   ```
   - **`rc_ps` is 0 or 1** (confirmed live: `ps` exits exactly `1` with empty stdout when the PID
     does not exist — the one documented absence signature; `0` is the normal "found it" case) —
     proceed to classify by `$state` below.
   - **`rc_ps` is anything else** (confirmed live: a missing `ps` binary on `PATH` exits `127`, a
     distinctly different code from the documented `1`) — an UNEXPECTED `ps` failure, not the
     documented absence case. Escalate to the human exactly like a stuck task; never silently
     reclassify this as "not alive" just because some exit code was nonzero.
   - **`$state` is empty** (`rc_ps` was 0 or 1, and nothing was printed — the documented "no such
     PID" case) — not alive — go to step 2.
   - **`$state` starts with `Z`** (zombie/defunct) — also not alive for the purpose of this check
     — go to step 2. If this poll is running inside the SAME dispatcher process that originally
     forked `spawn-sub-sup.sh` (not a restarted dispatcher — see the restart-safety note just
     above), additionally reap the zombie and free its process-table slot — but capture `wait`'s
     own return value rather than letting it propagate as a command failure:
     ```bash
     rc=0
     wait "$pid" 2>/dev/null || rc=$?
     if [ "$rc" -gt 4 ]; then
       : # ESCALATE independently of whatever .final.txt separately claims. An unexpected reaped
         # exit code (e.g. 42) is itself evidence something is wrong -- never fall through to
         # trusting the final-text file's own classification regardless of what $rc actually was.
     fi
     ```
     This capture is required, not optional: `wait "$pid"` returns the REAPED CHILD's own exit
     status (e.g. `4` for `SM_READY_UNMERGED`), and under `set -e` a bare `wait "$pid"` call with
     no `||` treats that nonzero status as `wait` itself failing — aborting the poll instead of
     treating `$rc` as `spawn-sub-sup.sh`'s terminal dispatch-report code and continuing (confirmed
     live: a bare `wait "$pid"` on a child that exited `4` killed the whole script with exit `4`,
     never reaching code after it; capturing via `rc=0; wait "$pid" || rc=$?` instead correctly
     recorded `rc=4` and let the script continue). But capturing `$rc` is not the same as trusting
     it blindly: `spawn-sub-sup.sh`'s own documented exit set is `{0,1,2,3,4}` (see "Strict-mode
     exit-code discipline" above) — a reaped `$rc` outside that set must escalate ON ITS OWN,
     independent of whatever `.final.txt` separately claims. Without the explicit `-gt 4` check
     above, an unexpected code (e.g. `42`) would fall through with NO escalation at all, and the
     dispatcher would go on to trust the final-text file's own classification regardless of what
     the reaped process actually exited with — even though a child exiting a code its own contract
     never defines is itself evidence something is wrong, whatever the final text superficially
     says. `waitpid()` itself still returns immediately (0.000s, confirmed live) for an
     already-exited child — it only blocks for a genuinely still-running child, which is not this
     branch. A restarted dispatcher cannot `wait` on a PID it never forked and does not need to:
     once the original parent process is truly gone, the kernel reparents any zombie it left behind
     to init/launchd, which reaps it on its own — the "not alive" classification above is already
     correct regardless of who, if anyone, performs the explicit reap.
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
2. **`.final.txt`'s presence/absence decides the outcome, checked with an explicit `[ -f ... ]`
   test — never implied by just attempting the call below:**
   ```bash
   final_txt=".secondmate/dispatch/${task_id}.final.txt"
   if [ -f "$final_txt" ]; then
   ```
   - **Present** — the process finished cleanly. Run `bin/dispatch-report.py` against it (section 1)
     to get the terminal exit code — using the SAME capture discipline as the zombie reap in step
     1, not a bare call, and classifying `$rc` against `dispatch-report.py`'s own real `{0,1,2,3,4}`
     contract from "Strict-mode exit-code discipline" above:
     ```bash
     rc=0
     bin/dispatch-report.py "$final_txt" || rc=$?
     if [ "$rc" -gt 4 ]; then  # exit codes are never negative; only the upper bound matters
       : # ESCALATE: outside dispatch-report.py's own documented {0,1,2,3,4} -- genuinely unexpected
     fi
     ```
     The explicit `[ -f "$final_txt" ]` test above is why this `dispatch-report.py` call is safe
     from the ambiguity the idiom table flags for this tool: confirmed live that calling
     `dispatch-report.py` on a file that does NOT exist raises an unhandled `FileNotFoundError` and
     ALSO exits `1` — the SAME code as a legitimate `SM_REFUSED`. Because this call only ever runs
     inside the `[ -f ... ]`-confirmed "Present" branch, that collision can never actually occur
     here; the file-missing case is routed to "Absent" below instead, before `dispatch-report.py`
     is ever invoked.

     The `rc` capture itself is required for the identical reason as `wait`'s above:
     `dispatch-report.py`'s exit code (`0`–`4`) IS the whole point of the call — not an error
     signal — and under `set -e` a bare, unguarded invocation treats ANY nonzero code (including
     `4` for `SM_READY_UNMERGED`, the single most common terminal outcome) as the command itself
     failing, aborting the strict dispatcher before it ever acts on the parsed result. Confirmed
     live: a bare, unguarded call against a real `.final.txt` containing
     `SM_READY_UNMERGED:deadbeef` killed the whole script with exit `4`, never reaching anything
     after it; capturing via `rc=0; bin/dispatch-report.py ... || rc=$?` instead correctly
     recorded `rc=4` and let the script continue to act on it. Nothing further to poll for this
     task-id once `$rc` is captured and classified within `{0,1,2,3,4}`.
   - **Absent** — an ANOMALY: the process is gone but never produced output (crashed, killed
     externally, etc.). Escalate to the human exactly like a stuck task. Never silently retry it,
     and never assume success just because the process is gone.
   ```bash
   fi
   ```

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

**Before building the entries file: filter `ready`'s output through `claim-ledger.py status`'s
currently-OPEN claims — a task-id whose claim is already gone must never be re-included.**
`progress-ledger.py`'s ledger rows are never deleted, so once a batch task-id reaches
`verify_gate_pass`, `bin/progress-ledger.py ready --batch-id <batch-id>` reports that SAME row
forever, even long after that task-id was merged, its claim released, and its worktree torn down
in a prior round of this same batch. If the dispatcher process restarts after that point and
re-runs its batch-close logic, it would recompute the ready set from the ledger alone and open a
SECOND consolidated hold entry for an already-merged, already-answered, already-torn-down task-id.
`skills/secondmate/SKILL.md`'s own batch-dispatch step (e) already documents the fix for exactly
this: "Cross-check against `bin/claim-ledger.py status`'s own currently-OPEN claims too — anything
already merged and released from a prior round of this same batch drops out on its own, since its
claim is gone." Carry that same cross-check into this skill's own batch-close concretely:
```bash
open_claims_output=$(bin/claim-ledger.py status)
# status's own contract is binary like hold.py open: 0 = success, always, even with zero open
# claims (confirmed live: "(no open claims)" to stderr, exit 0) -- no classification needed here,
# unlike `ready`, which the parent skill's own fan-out section documents as "always exits 0" too.
ready_output=$(bin/progress-ledger.py ready --batch-id "$batch_id")
entries_task_ids=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  tid=$(printf '%s' "$line" | jq -r '.task_id')
  if printf '%s\n' "$open_claims_output" | grep -qF "[$tid] "; then
    entries_task_ids+=("$tid")  # claim still open -- keep, this task-id genuinely awaits this hold
  fi
  # else: claim already gone -- already merged/answered/torn down in a prior round of this same
  # batch. DROP it. Never re-include a task-id whose claim-ledger entry is already closed.
done <<< "$ready_output"
```
Confirmed live: simulated a two-task-id batch where `t1` was already merged and its claim released
in a prior round while `t2` was still pending — `ready --batch-id` kept reporting BOTH `t1` and
`t2` (ledger rows never deleted, exactly the bug surface), but `claim-ledger.py status` reported
only `t2` as open; the filter above correctly dropped `t1` and kept only `t2`.

Then write the JSON entries file, one object per task-id that survived the filter above —
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
survive under strict mode. **But `hold.py open`'s own exit code and the match-search below must be
captured SEPARATELY, never collapsed into one blanket `|| true`** — `hold.py open` itself can
genuinely fail (confirmed live: pointed `SM_HOLD_LEDGER` at a directory instead of a file, a real
ledger I/O error, and `hold.py open` crashed with an unhandled `IsADirectoryError` and exited `1`).
Collapsing both into one guard would make a genuine `hold.py open` failure look identical to "no
existing hold" and fall through into opening a brand-new hold on top of an unresolved tool
failure. Run `hold.py open` on its own line first, capturing its OWN exit code:
```bash
rc_open=0
hold_output=$(bin/hold.py open) || rc_open=$?
```
- **`rc_open` is nonzero** — `hold.py open` itself failed; this is NOT the "no open holds" case.
  Escalate to the human verbatim exactly like a stuck task; do not proceed to open a new hold on
  top of an unresolved failure.
- **`rc_open` is `0`** — `hold.py open` succeeded (confirmed live: it exits `0` even when it finds
  zero open holds, printing `(no open decisions)` to stderr). Only now is it safe to search its
  captured output for a match. `hold.py open`'s own output format is `[<id>] (<task>) <question>`
  per open hold — a known, fixed shape (strip the leading `[`, take everything up to the first
  `]`), simple enough to extract with pure bash parameter expansion instead of an external-tool
  pipeline (`grep`/`head`/`sed`), eliminating the whole class of "what if `sed`/`head` itself fails
  unexpectedly" findings rather than adding another `rc=$?` branch for yet another tool:
  ```bash
  existing_id=""
  while IFS= read -r line; do
    if [[ "$line" == "["*"] (<batch-label>)"* ]]; then
      existing_id="${line#\[}"      # strip the leading "["
      existing_id="${existing_id%%\]*}"  # keep everything before the first "]"
      break
    fi
  done <<< "$hold_output"
  ```
  No external tool runs in this extraction at all — `[[ ... ]]` and `${...}` are bash builtins, so
  there is no second exit code to capture or classify here; the only exit code that mattered was
  `hold.py open`'s own, already handled above. Confirmed live against the real
  `[dcfa5ec7] (batch-abc123) merge which of: t1?` output shape: correctly extracted `dcfa5ec7` when
  the batch label matched, and correctly left `existing_id` empty when no line matched.

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

**`merge-sequencer.sh`'s own exit code must be captured, never left to a bare call under
`set -e`.** Its full documented exit set for a normal (non-`--preflight-only`) invocation is
`{0,1,2,3,4,5}` (see "Strict-mode exit-code discipline" above) — codes `1`–`5` are ALL genuinely
expected refusal/failure outcomes (gate refusal, usage error, merge conflict, push failure, lock
timeout), not something the dispatcher is supposed to treat as a crash. A bare, unguarded call
would, under `set -e`, die on the FIRST such refusal (e.g. a stale `--checked-sha` giving exit
`1`) before the dispatcher's own "only clean up on success" logic below ever runs — never reaching
it, never relaying the refusal, just an abrupt, uncommunicative script death:
```bash
rc=0
bin/merge-sequencer.sh --repo <repo> --worktree <worktree> --branch "sm/<task-id>" --base main \
  --checked-sha <that entry's checked_sha> || rc=$?
if [ "$rc" -gt 5 ]; then  # exit codes are never negative; only the upper bound matters
  : # ESCALATE: outside merge-sequencer.sh's own documented {0,1,2,3,4,5} -- e.g. 126/127 if the
    # script itself couldn't even run. Genuinely unexpected, never treated as any refusal reason.
fi
```
**Only when `rc` is `0`** does the dispatcher run the follow-on cleanup — never unconditionally:
```bash
if [ "$rc" -eq 0 ]; then
  if command -v herdr >/dev/null 2>&1; then
    herdr worktree remove --workspace <workspace-id>
  else
    git -C <repo> worktree remove <worktree>
  fi
  git branch -d "sm/<task-id>"
  bin/claim-ledger.py release --task-id <task-id> --owner "sm-<task-id>" --token <token from section 3>
  bin/teardown-check.sh --task-id <task-id>
fi
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

**On any `rc` in `{1,2,3,4,5}`** (a documented refusal reason — e.g. it refuses a stale
`--checked-sha`, `rc=1`) **or outside `{0,...,5}` entirely** (a genuinely unexpected failure), the
dispatcher leaves the worktree, branch, and claim exactly as they are — do not remove the
worktree, delete the branch, or release the claim — and relays the failure (citing `$rc` and
`merge-sequencer.sh`'s own ledger `reason_code` for the documented cases) to the human, the same
discipline as a stuck/refused task. Running the cleanup unconditionally discards an unmerged,
still-good task's work and frees its task-id for someone else to claim out from under it.

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
