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
- **One explicit exception to "unchanged": Spawn.** When this external dispatcher does the
  spawning, it has already created the worktree and `cd`'d into it before `claude -p` even starts
  (section 1) — the sub-supervisor's own copy of the parent SOP's Spawn step must not create a
  second one. See section 1's "Spawn is the one overridden step" below for the exact override to
  put in the sub-supervisor's prompt.

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

**Every shared dispatch artifact below — the manifest, the `.pid` sidecar, the `stream-json` log,
the extracted `.final.txt`, and the batch manifest — is addressed by an ABSOLUTE path, never a bare
`.secondmate/dispatch/<task-id>.foo` that silently changes meaning depending on the caller's current
working directory.** Two different processes touch these files from two different working
directories over a single task's lifetime: the dispatcher itself, and the sub-supervisor's own
`spawn-sub-sup.sh`/`claude -p` process, which — per step 0 below — `cd`s into the task's worktree
before anything else runs. A relative path resolves against WHICHEVER of those happens to be the
current process's CWD at that moment — silently wrong, landing inside the worktree instead of the
primary repo, for anything written after that `cd` (the `.jsonl`/`.final.txt` writes in steps 1–2
below, and the checker-pane-id patch below). Confirmed live: a throwaway script that `cd`'d into a
scratch "worktree" directory and then wrote to the bare relative path `.secondmate/dispatch/x.txt`
created that file INSIDE the scratch directory, invisible to a separate process still watching the
original directory's `.secondmate/dispatch/x.txt` — the exact failure this fixes. The dispatcher
resolves one absolute variable, `dispatch_dir`, once, before fanning out anything — e.g.
`dispatch_dir="$(git -C <repo> rev-parse --show-toplevel)/.secondmate/dispatch"` — and every path
below that mentions `.secondmate/dispatch/<id>.foo` means `"$dispatch_dir/<id>.foo"`, passed through
explicitly, never re-derived from an assumed CWD.

**Invocation (by the dispatcher, backgrounding `spawn-sub-sup.sh` itself):**
```bash
bin/spawn-sub-sup.sh --task-id <task-id> --prompt-file <path> --log-dir "$dispatch_dir" \
  --worktree "$worktree_path" &
echo $! > "$dispatch_dir/<task-id>.pid"
```
`--log-dir` is passed as the already-absolute `$dispatch_dir`, not a relative literal — this is the
one value `spawn-sub-sup.sh` carries forward into steps 1–2 below (bound there as `$log_dir`),
unaffected by its own step-0 `cd`.
PID bookkeeping now lives with the **dispatcher**, not inside the script: the dispatcher
backgrounds the one process whose whole lifecycle matters and captures `$!` as its very next
action, immediately after backgrounding it — the same idiom as before, just relocated to the
caller, where it is trivially correct (no "before/after fork" ambiguity, because there is exactly
one thing being forked and exactly one thing being tracked). `$!` is still only available *after*
the `&` backgrounding has actually happened (confirmed live: a probe script printed `$!` as empty
immediately before backgrounding a process, and only non-empty immediately after) — so this
capture is necessarily the dispatcher's next line, never something done beforehand.

**Before backgrounding `spawn-sub-sup.sh`: create the worktree (and, if herdr is in use, its
workspace/pane) and durably record every identifier later recipes need — never leave them as
in-memory values the dispatcher is assumed to still remember.** Section 4's watchdog pane filter
and section 7's merge cleanup both reference `<workspace-id>`, `<worktree>`, `root_pane_id`, and
`checker_pane_id` — an external OS-level process has no in-session context to recover these from
after the sub-supervisor process exits or the dispatcher itself restarts, so they must be written
to disk at the moment they're first known, the same discipline the batch manifest (section 5)
already applies at the batch level:
- **Headless / no herdr:** `read wt branch < <(bin/new-worktree.sh --repo <repo> --task <task-id>)`
  — the same primitive `skills/secondmate/SKILL.md`'s own headless path uses — then
  `worktree_path="$wt"`. **This assignment is required, not cosmetic:** `new-worktree.sh`'s own
  output goes into `$wt`/`$branch`, never a variable literally named `worktree_path` — the manifest
  write below references `$worktree_path` specifically, and under `set -u` (part of this file's own
  `set -euo pipefail` discipline) referencing it while only `$wt` was ever assigned is an unbound-
  variable crash, confirmed live: the unfixed form died with `worktree_path: unbound variable`
  before the manifest was ever written, meaning the dispatch never got off the ground on the normal
  no-herdr path. No workspace/pane identifiers exist in this path.
- **herdr in use:** `result=$(herdr worktree create --cwd <repo> --branch sm/<task-id> --base HEAD
  --label sm-<task-id> --no-focus)`, then `worktree_path=$(printf '%s' "$result" | jq -r
  '.result.worktree.path')`, `root_pane_id=$(printf '%s' "$result" | jq -r
  '.result.root_pane.pane_id')`, and `workspace_id=$(printf '%s' "$result" | jq -r
  '.result.workspace.workspace_id')` — the first two are the identical JSON paths
  `skills/secondmate/SKILL.md`'s own `herdr worktree create` call already relies on (confirmed by
  reading that file's Spawn step 2 directly); the third, `workspace_id`, is confirmed live against
  a real `herdr worktree create` response (e.g. `"w76"`). **This extraction is required, not
  optional:** an earlier draft of this contract left `workspace_id` unassigned here and the
  manifest write below silently fell back to its own `${workspace_id:-}` default (an empty string,
  serializing to JSON `null`) EVERY time, herdr or not — confirmed live, the unfixed form produced
  `"workspace_id": null` even against a real herdr response that actually carried `"w76"`. Section
  7's merge-cleanup branches on this exact field to choose `herdr worktree remove --workspace <id>`
  over the git fallback; without this line, it always fell through to the git fallback, herdr or
  not.

Either way, write a durable per-task manifest IMMEDIATELY, atomically (temp file + `mv`, the same
idiom this skill already requires for round-state files elsewhere):
```bash
jq -n --arg task_id "<task-id>" --arg worktree_path "$worktree_path" \
      --arg workspace_id "${workspace_id:-}" --arg root_pane_id "${root_pane_id:-}" \
  '{task_id: $task_id, worktree_path: $worktree_path,
    workspace_id: ($workspace_id | select(. != "") // null),
    root_pane_id: ($root_pane_id | select(. != "") // null),
    checker_pane_id: null}' > "$dispatch_dir/<task-id>.manifest.json.tmp"
mv "$dispatch_dir/<task-id>.manifest.json.tmp" "$dispatch_dir/<task-id>.manifest.json"
```
An empty/unset `workspace_id` or `root_pane_id` (the headless path) correctly serializes to JSON
`null`, not an empty string — confirmed live: `jq -r '.workspace_id'` on a `null` field prints the
literal string `null`, so every later reader must check `[ "$ws" = "null" ]`, not just
`[ -z "$ws" ]`. Confirmed live end-to-end: wrote this manifest for a headless (no-herdr) task-id,
then re-read it from a **separate** process invocation simulating a dispatcher restart — the
`worktree_path` and the correctly-`null` `workspace_id`/`root_pane_id` both came back identical to
what was written, with no in-memory state involved at all.

**If a checker pane is later split off (the visible-orchestration case), patch THIS SAME manifest
file immediately after the split call — this is the one, concrete step that actually performs the
update an earlier draft only described in prose without ever showing it.** The split itself is
`skills/secondmate/SKILL.md`'s own documented call (confirmed by reading its "Checker pane" recipe
directly): `ck=$(bin/herdr-pane.sh split --pane <root_pane_id> --dir down)` — run by the
sub-supervisor's OWN running session, which (per step 0 below) has already `cd`'d into the
worktree. So this patch must address the manifest by the SAME absolute path the dispatcher wrote
it to, never a relative one re-derived from this session's own (now worktree-rooted) CWD: right
after `$ck` is returned, patch the manifest atomically — same temp-file + `mv` idiom as the
original write, never a direct in-place edit:
```bash
jq --arg checker_pane_id "$ck" '.checker_pane_id = $checker_pane_id' \
  "$dispatch_dir/<task-id>.manifest.json" > "$dispatch_dir/<task-id>.manifest.json.tmp"
mv "$dispatch_dir/<task-id>.manifest.json.tmp" "$dispatch_dir/<task-id>.manifest.json"
```
Since this session has no way to recover `$dispatch_dir` on its own after `cd`-ing into the
worktree (it is not an env var or flag the parent SOP itself knows about), the dispatcher must bake
this literal absolute path directly into the `--prompt-file` text it writes for this task-id, as
part of describing this one patch step — the same way it must bake the Spawn override in (see
"Spawn is the one overridden step" below).

No other step in this file ever performs this update — if a deployment never splits a checker
pane (the common headless case), `checker_pane_id` legitimately stays `null` forever, and nothing
elsewhere should assume otherwise. Section 4's watchdog (below) re-reads this field fresh every
poll cycle rather than caching a stale value from spawn time, so this patch becomes visible to the
watchdog on its very next iteration after the split, with no restart required.

**Inputs:** a `--task-id` (validated by the dispatcher before the call — see Discipline below), a
`--prompt-file` holding the full sub-supervisor prompt (claim → SOP → completion tag, same prompt
shape as the Agent-tool version, plus the `SM_CLAIM_TOKEN:` line required below), a `--log-dir`
(the dispatcher's own absolute `$dispatch_dir`, never a relative path — see above), and a
`--worktree <path>` — the SAME pre-created worktree path the dispatcher just wrote into this
task-id's manifest above (`$worktree_path`/`$wt`), passed through explicitly rather than assumed.
**This input is required, not optional:** without it, nothing in this contract ever tells the
spawned `claude -p` process to run from the worktree the dispatcher already created for it — as
documented, the fresh sub-supervisor could end up running its whole SOP from the dispatcher's own
CWD instead. The simplest, most consistent fix with this file's existing conventions (every other
recipe here passes paths through explicitly, never relies on an unstated ambient CWD) is for
`spawn-sub-sup.sh` to `cd` into `--worktree` itself, as the literal first action, before anything
else — see step 0 below.

**Spawn is the one overridden step.** `skills/secondmate/SKILL.md`'s own Spawn step (step 2 of its
SOP) ALSO creates a worktree — via `herdr worktree create` or `new-worktree.sh` — because in the
ordinary in-session case nothing has created one yet when that step runs. Here the opposite is
true: this dispatcher (above, "Before backgrounding...") already created the worktree, and
`spawn-sub-sup.sh` has already `cd`'d into it (step 0 below) before `claude -p` even starts. A
sub-supervisor that ran the parent SOP's Spawn step completely unmodified would try to create a
SECOND worktree on the same branch/path and fail outright before getting anywhere else. Confirmed
live: running `new-worktree.sh`'s own underlying `git worktree add -b <branch> <path> <base>` a
second time against a branch/path pair a prior call had already created failed with `fatal: a
branch named '<branch>' already exists` and a nonzero exit — the sub-supervisor would die on its
own Spawn step, never reaching Plan Committee or anything after it.

So every sub-supervisor prompt this dispatcher writes to `--prompt-file` must say, for Spawn
specifically and ONLY Spawn: do not call `herdr worktree create` or `new-worktree.sh` — this
process is already running from the correct worktree (its own CWD, per step 0 below); instead,
read `"$dispatch_dir/<task-id>.manifest.json"` (the dispatcher-written absolute path from above)
for the `worktree_path`, `root_pane_id`, and `workspace_id` this dispatcher already recorded, and
treat Spawn as already complete. Every other step of the parent SOP — Plan Committee, Triage,
Guard, Check, Gate, Hold, Integrate, Teardown — runs completely unchanged, exactly as
`skills/secondmate/SKILL.md` already documents it. The sub-supervisor's own session cannot recover
`$dispatch_dir` any other way after this `cd` (it is not an env var or flag the parent SOP itself
knows about), so this literal absolute path must be baked directly into the generated prompt text,
not left for the sub-supervisor to re-derive.

**Behavior, in order (inside `spawn-sub-sup.sh` itself, all synchronous):**
0. `cd` into `--worktree` — the VERY FIRST action, before `claude -p` or anything else runs. Every
   subsequent step, including the `claude -p` invocation itself, runs with this as the working
   directory, so the sub-supervisor's whole claim → SOP → completion-tag run happens inside the
   worktree the dispatcher already created for it, never the dispatcher's own ambient CWD. This
   `cd` does NOT affect `$log_dir` (bound from the already-absolute `--log-dir` input) — steps 1–2
   below address artifacts through that absolute value, never a path relative to this new CWD.
1. Run `claude -p --output-format stream-json` for that task-id and prompt, in the foreground,
   piping its output through `tee` to `"$log_dir/<task-id>.jsonl"` as it streams, and
   **block until that invocation exits.** Never `--continue` or `--resume` — every sub-supervisor
   must start with zero inherited context, the exact same "Agent tool, never fork" discipline
   `skills/secondmate/SKILL.md` already requires for the in-session case, just enforced via process
   flags instead of a tool-call parameter.
2. Once `claude -p` has exited, extract the final assistant message's plain-text content out of
   the `.jsonl` log into `"$log_dir/<task-id>.final.txt"`.
3. Run `bin/dispatch-report.py` against that `.final.txt` file — **never** the raw `.jsonl`.
   `dispatch-report.py`'s own completion-tag regex is anchored at the start of a line; a completion
   tag that happens to appear inside a JSON string value in the raw stream (e.g. quoted inside a
   `"text": "...SM_DONE_MERGED:abc123..."` field) would never match there, so only the extracted
   plain text is a valid target.
4. Exit with `dispatch-report.py`'s own exit code **verbatim** — never a raw bash `$?` from the
   `claude -p` process itself (that reflects the CLI's own exit status, not the parsed completion
   tag). This is also the exit code the dispatcher's own `ps -o stat=`-based liveness check and
   `wait`-based reap see (section 5), since steps 1–4 all run inside the one PID it is tracking.

**Outputs:** `"$log_dir/<task-id>.jsonl"` (raw) and `"$log_dir/<task-id>.final.txt"`
(extracted plain text) — both absolute, written by `spawn-sub-sup.sh` itself.
`"$dispatch_dir/<task-id>.pid"` (liveness sidecar, the same absolute directory as `$log_dir`) is
written by the **dispatcher**, not by `spawn-sub-sup.sh` — see the invocation recipe above.

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

Every spawned sub-supervisor leaves exactly four artifacts under `$dispatch_dir`
(`.secondmate/dispatch/` under the primary repo's own checkout, as an absolute path — see section 1):
- `<task-id>.jsonl` — the raw `stream-json` transcript, written by `spawn-sub-sup.sh` itself,
  append-only, useful for a human reading back what actually happened.
- `<task-id>.final.txt` — the extracted plain-text content of the final assistant message only,
  also written by `spawn-sub-sup.sh` itself. This is the ONLY file the dispatcher parses
  programmatically — both for `dispatch-report.py` (section 1) and for the claim-token line
  (section 3).
- `<task-id>.pid` — the liveness sidecar, written by the **dispatcher** (not `spawn-sub-sup.sh`)
  immediately after backgrounding it (section 1). Used by the watchdog's reap check (section 5).
- `<task-id>.manifest.json` — the worktree/herdr-identifier manifest, written by the
  **dispatcher** (section 1) BEFORE backgrounding `spawn-sub-sup.sh`, holding `worktree_path`,
  `workspace_id`, `root_pane_id`, and `checker_pane_id` (the last `null` until/unless a checker
  pane is split off). Read back by the watchdog's pane filter (section 4) and the merge-cleanup
  recipe (section 7) — durable on disk, so both survive a dispatcher restart with no in-memory
  state to recover.

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
matched=$(grep '^SM_CLAIM_TOKEN:' "$dispatch_dir/${task_id}.final.txt") || rc_g=$?
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
      # Re-read EVERY watched task-id's own manifest FRESH, this cycle — never cached from spawn
      # time or a prior iteration, so a checker-pane patch (section 1) becomes visible on the very
      # next loop iteration after it happens, with no restart required. Build the pane-id filter
      # dynamically, skipping any field a manifest reports as the literal string "null" (no herdr
      # pane for that identifier at all), never filtering on that literal string itself.
      pane_grep_args=()
      for task_id in "${task_id_flags[@]}"; do
        manifest="$dispatch_dir/${task_id}.manifest.json"
        root_pane_id=$(jq -r '.root_pane_id' "$manifest")
        checker_pane_id=$(jq -r '.checker_pane_id' "$manifest")
        [ "$root_pane_id" != "null" ] && pane_grep_args+=(-e "\"pane_id\": \"${root_pane_id}\"")
        [ "$checker_pane_id" != "null" ] && pane_grep_args+=(-e "\"pane_id\": \"${checker_pane_id}\"")
      done
      if [ "${#pane_grep_args[@]}" -gt 0 ]; then
        printf '%s\n' "$quiet_output" | grep -F "${pane_grep_args[@]}" || true
        # the `|| true` here is honestly sufficient (no fix needed): this grep reads a captured
        # STRING via printf, never a filename argument, so its real {0,1,2} contract collapses to
        # {0,1} at this call site -- a "file not found" exit 2 is structurally impossible here.
      fi
      # if pane_grep_args is empty (every watched task-id is headless, no herdr pane at all),
      # skip the grep call entirely -- calling `grep -F` with zero -e flags is a usage error, not
      # "match nothing," so this guard is required, not decorative.
    fi
  fi
  # relay any hit/escalation from any of the three calls above to the human verbatim, exactly as
  # the in-session watchdog does — never restart, never steal, never treat a hit as a confirmed crash
  sleep "$N"
done
```

**This re-reads EVERY watched task-id's own `<task-id>.manifest.json` (section 1/2) fresh, every
single poll cycle — never an in-memory value, and never a value cached from an earlier iteration
of this SAME loop.** This is what makes the pane filter restart-safe AND checker-pane-aware: a
dispatcher that crashes and comes back has no conversation context left, but the manifest files on
disk are exactly what it already needed to re-derive before it could even resume watching these
task-ids; and a checker pane split off mid-task (section 1's patch step) is picked up on the very
next cycle, since the loop never trusts a value it read in a prior iteration. Confirmed live:
built the pane-id filter for two task-ids (one with a real `root_pane_id`, one fully headless with
both fields `null`) and confirmed the filter correctly included only the real pane id; separately
confirmed the all-headless edge case (every watched task-id's manifest reports `null` for both
fields) correctly skips the `grep` call entirely rather than invoking it with zero `-e` flags.

**Every example invocation here must be a complete, directly-runnable command — no literal "..."
left sitting where a real argument belongs.** A trailing `...` after a `grep -F -e PATTERN` call is
not a harmless placeholder: `grep` reads it as an actual extra argv token, and `grep -F -e PATTERN
<extra-arg>` interprets that extra token as a FILENAME to read instead of stdin — so a real
quiet-pane hit arriving on stdin never gets matched, `grep` fails on the missing file, and a
trailing `|| true` would silently swallow a hit that should have been relayed to the human.
Confirmed live: piping a real `pane-reaper.py quiet`-shaped JSON line (built from reading
`find_quiet`'s own hit-dict construction directly:
`{"pane_id": pane_id, "status": "quiet", ...}`) into a literal `grep -F -e "..." ...` form produced
`grep: ...: No such file or directory` and exit 2 — the hit was never seen. The dynamically-built
`${pane_grep_args[@]}` array above never contains a literal `...` — every `-e` entry it adds is a
real, concrete pane-id pattern read straight from a manifest.

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
   sidecar_pid=$(cat "$dispatch_dir/${task_id}.pid" 2>/dev/null)
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
   final_txt="$dispatch_dir/${task_id}.final.txt"
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
manifest file at the same absolute `$dispatch_dir` as every other artifact above:
```
$dispatch_dir/<batch-id>.batch.json
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

**Before building the entries file: filter `ready`'s output through THREE things — this batch's
own persisted task-id list, `claim-ledger.py status`'s currently-OPEN claims, AND this batch's own
durable hold-history — never trust `ready --batch-id` alone as proof a row belongs to THIS
dispatcher's own batch, or that it hasn't already been decided.** Three independent reasons a row
from `ready --batch-id <batch-id>` must not be taken at face value:
1. `progress-ledger.py`'s ledger rows are never deleted, so once a batch task-id reaches
   `verify_gate_pass`, `ready --batch-id` reports that SAME row forever, even long after that
   task-id was merged, its claim released, and its worktree torn down in a prior round of this
   same batch. `skills/secondmate/SKILL.md`'s own batch-dispatch step (e) already documents the
   fix: "Cross-check against `bin/claim-ledger.py status`'s own currently-OPEN claims too —
   anything already merged and released from a prior round of this same batch drops out on its
   own, since its claim is gone."
2. **`<batch-id>` collision across independent dispatcher runs is a known, documented limit
   elsewhere in this file (section 5's batch manifest discussion)** — `ready --batch-id` has no way
   to tell "a task-id THIS dispatcher's own batch actually spawned" apart from "a wholly unrelated
   task-id from a different dispatcher run that happens to carry the identical `<batch-id>` value."
   Confirmed live: simulated a batch whose own persisted task-id list was `["mine1", "mine2"]`, but
   recorded a THIRD, unrelated task-id (`foreign1`) at `verify_gate_pass` under the SAME
   `<batch-id>` — `ready --batch-id` returned BOTH `mine1` and `foreign1`, and `claim-ledger.py
   status` reported BOTH as open (`foreign1`'s claim is real, just not this batch's), so the
   claim-status filter alone could not tell them apart and wrongly kept `foreign1`. Only cross-
   checking against this batch's own `<batch-id>.batch.json` (section 5) — which lists EXACTLY the
   task-ids this dispatcher's own fan-out actually spawned — correctly excludes it.
3. **A REJECTED task-id's claim is deliberately left open (section 7's own documented rule:
   "left completely untouched... claimed, needs rework") — so the first two checks alone cannot
   tell "ready and never yet asked about" apart from "already rejected by a human in a prior hold
   for this exact batch-id."** `hold.py open` only shows currently-OPEN holds; once a hold is
   answered it simply disappears from that view, so the "search for an existing open hold, open a
   new one if none is found" logic below (re-)opens a BRAND-NEW hold asking the human to
   re-adjudicate a task-id they already rejected, every time the dispatcher restarts and nothing
   has changed. Confirmed live: opened a hold covering `t1`, answered it `--reject t1`, then
   re-ran the exact "no open hold found → open a new one" logic — it found nothing in `hold.py
   open`'s output (correctly empty, the hold is closed) and opened a SECOND hold for the identical,
   unchanged `t1`. The fix needs a durable record of what this batch already asked a human about,
   independent of `hold.py open`'s open-only view — see "Hold history: the third durable artifact"
   below.

**Hold history: the third durable artifact.** Alongside `<batch-id>.batch.json` (section 5), this
dispatcher also durably records every hold-id it has ever opened for this batch-id, at
`$dispatch_dir/<batch-id>.hold-history.json` — a JSON array of
`{"hold_id": "...", "entries": [{"task_id": ..., "checked_sha": ..., ...}, ...]}`, one record per
hold ever opened (not just the currently-open one), written atomically (read, append, temp+`mv`,
the same idiom as every other durable write in this file) the moment a NEW hold is opened (see the
updated "open a new one" step below). A hold-id, once answered, is never reopened or reanswered
(confirmed by reading `hold.py`'s own `_recs()`/`answer` handling directly: an already-answered id
is rejected outright) — so a REJECTED decision recorded against a specific `checked_sha` is
permanent for that `checked_sha`, and remains valid evidence across any number of dispatcher
restarts without needing `hold.py open`'s live, open-only view at all. Reading whether a given
historical hold-id was answered, and what it decided, means reading `hold.py`'s own ledger
directly at `${SM_HOLD_LEDGER:-decisions.jsonl}` — the identical path hold.py itself resolves
(confirmed by reading its own `LEDGER = pathlib.Path(os.environ.get("SM_HOLD_LEDGER",
"decisions.jsonl"))` directly) — for the `{"ev": "answer", "id": "<hold-id>"}` record hold.py's
own module docstring documents as its real, stable answer shape, extracting `.rejected[]`. This is
reading a tool's own documented, stable on-disk contract directly, the same discipline this file
already applies to `dispatch-report.py`'s regex, `claim-ledger.py`'s `_TOKEN_RE`, and
`pane-reaper.py`'s exit codes elsewhere — not a second, parallel definition of "rejected."

A rejected decision only disqualifies a task-id for the EXACT `checked_sha` it was rejected at —
never for a later, genuinely different `checked_sha`. A human-driven rework/resubmission round
produces a brand-new `verify_gate_pass` row with a new `checked_sha` (ordinary dispatcher
discipline, unchanged), which is exactly the signal this file already treats as "legitimately
different" everywhere else (`merge-sequencer.sh`'s own `--checked-sha` anti-reattachment gate,
`hold.py`'s own `--sha` binding). Comparing on `"<task-id>@<checked_sha>"` pairs, not bare
task-ids, is what lets a genuine resubmission through while still excluding an unchanged, already-
rejected one.

Carry all three cross-checks into this skill's own batch-close concretely:
```bash
open_claims_output=$(bin/claim-ledger.py status)
# status's own contract is binary like hold.py open: 0 = success, always, even with zero open
# claims (confirmed live: "(no open claims)" to stderr, exit 0) -- no classification needed here,
# unlike `ready`, which the parent skill's own fan-out section documents as "always exits 0" too.
batch_task_ids=$(jq -r '.task_ids[]' "$dispatch_dir/${batch_id}.batch.json")
ready_output=$(bin/progress-ledger.py ready --batch-id "$batch_id")

# Build the rejected_unchanged set from this batch's own hold history -- independent of
# hold.py open's open-only view (that view cannot distinguish "never asked" from "already
# answered"); an answered hold-id is permanent, so this is safe to trust across any restart.
history_file="$dispatch_dir/${batch_id}.hold-history.json"
[ -f "$history_file" ] || echo '[]' > "$history_file"
rejected_unchanged=()
while IFS= read -r hrec; do
  hid=$(printf '%s' "$hrec" | jq -r '.hold_id')
  answer_rec=$(jq -c --arg id "$hid" 'select(.ev == "answer" and .id == $id)' \
    "${SM_HOLD_LEDGER:-decisions.jsonl}")
  [ -z "$answer_rec" ] && continue   # not yet answered -- nothing to exclude for this hold-id
  rej_ids=$(printf '%s' "$answer_rec" | jq -r '.rejected[]? // empty')
  while IFS= read -r rid; do
    [ -z "$rid" ] && continue
    rsha=$(printf '%s' "$hrec" | jq -r --arg t "$rid" '.entries[] | select(.task_id == $t) | .checked_sha')
    rejected_unchanged+=("${rid}@${rsha}")
  done <<< "$rej_ids"
done < <(jq -c '.[]' "$history_file")

entries_task_ids=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  tid=$(printf '%s' "$line" | jq -r '.task_id')
  sha=$(printf '%s' "$line" | jq -r '.checked_sha')
  claim_open=0
  printf '%s\n' "$open_claims_output" | grep -qF "[$tid] " && claim_open=1
  in_batch=0
  printf '%s\n' "$batch_task_ids" | grep -qxF "$tid" && in_batch=1
  already_rejected=0
  for ru in "${rejected_unchanged[@]:-}"; do
    [ "$ru" = "${tid}@${sha}" ] && already_rejected=1 && break
  done
  if [ "$claim_open" -eq 1 ] && [ "$in_batch" -eq 1 ] && [ "$already_rejected" -eq 0 ]; then
    entries_task_ids+=("$tid")  # claim open, genuinely ours, AND not already decided -- keep
  fi
  # else: the claim is already gone (merged/torn down in a prior round of THIS batch), this row
  # never belonged to this batch at all (a batch-id collision with a foreign task-id), or a human
  # already rejected this EXACT checked_sha in a prior round of THIS batch. DROP it either way.
  # Never re-include a task-id that fails any of the three checks.
done <<< "$ready_output"
```
Confirmed live, three scenarios: (1) a two-task-id batch where `t1` was already merged and its
claim released in a prior round while `t2` was still pending — `ready --batch-id` kept reporting
BOTH (ledger rows never deleted), but the claim-status half of the filter correctly dropped `t1`
and kept only `t2`; (2) the batch-id-collision scenario above — the claim-status check ALONE
wrongly kept the foreign `foreign1` (`claim_open=1`), but adding the batch-manifest membership
check (`in_batch=0` for `foreign1`) correctly dropped it while still keeping the genuine `mine1`;
(3) the rejected-and-unchanged scenario this round fixes — opened a hold for `t1@sha-aaa111`,
rejected it, recorded that hold into `hold-history.json`, then re-ran this exact filter on a
simulated restart: `entries_task_ids` correctly came back empty (the rejection, unchanged, is
excluded) — then recorded a NEW `verify_gate_pass` row for `t1` at a genuinely different
`checked_sha` (a real rework resubmission) and re-ran the identical filter again: `t1` correctly
reappeared in `entries_task_ids`, confirming the exclusion is scoped to the exact rejected
`checked_sha`, never to the bare task-id.

Then write the JSON entries file, one object per task-id that survived the filter above, to
`entries_file="$dispatch_dir/${batch_id}.entries.json"` —
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
- **No matching open hold is found** (`$existing_id` is empty) — only then open a new one, and
  immediately record it into `hold-history.json` above — this is what makes the rejected-and-
  unchanged exclusion restart-safe: without this write, a dispatcher that restarts between opening
  this hold and it being answered would have no durable way to ever learn this hold-id existed:
```bash
new_hold_id=$(bin/hold.py hold --task "$batch_id" --q "merge which of: <task-id-1>, <task-id-2>, ...?" \
  --entries-file "$entries_file")
tmp="$history_file.tmp"
jq --arg hid "$new_hold_id" --slurpfile entries "$entries_file" \
  '. + [{hold_id: $hid, entries: $entries[0]}]' "$history_file" > "$tmp"
mv "$tmp" "$history_file"
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
**`<workspace-id>` and `<worktree>` are read from this task-id's own `<task-id>.manifest.json`
(section 1/2), never an in-memory value from whenever the worktree was originally created** — the
same restart-safety reason section 4's pane filter now reads from the SAME manifest:
```bash
workspace_id=$(jq -r '.workspace_id' "$dispatch_dir/<task-id>.manifest.json")
worktree=$(jq -r '.worktree_path' "$dispatch_dir/<task-id>.manifest.json")
```
**Only when `rc` is `0`** does the dispatcher run the follow-on cleanup — never unconditionally:
```bash
if [ "$rc" -eq 0 ]; then
  if command -v herdr >/dev/null 2>&1 && [ "$workspace_id" != "null" ]; then
    herdr worktree remove --workspace "$workspace_id"
  else
    git -C <repo> worktree remove "$worktree"
  fi
  git branch -d "sm/<task-id>"
  bin/claim-ledger.py release --task-id <task-id> --owner "sm-<task-id>" --token <token from section 3>
  bin/teardown-check.sh --task-id <task-id> --repo <repo>
fi
```
**`teardown-check.sh` must always get `--repo <repo>` explicitly, never left to its own default.**
`teardown-check.sh` defaults `--repo` to `.` when omitted (confirmed by reading its own argument
parsing directly) — for an external dispatcher running from a non-repository CWD (the normal
cron/daemon case this whole skill targets), that default resolves to a path that isn't a git
working tree at all. Confirmed live: ran `teardown-check.sh --task-id t1 --repo <a real non-repo
path>` directly and it printed `--repo <path> is not a git working tree` and exited `2` — the same
failure a bare `--task-id`-only call would hit the moment the dispatcher's actual CWD isn't inside
`<repo>`, instead of confirming cleanup on the real target repo. Every other recipe in this file
already carries `<repo>` through explicitly (`merge-sequencer.sh`, `git -C <repo> worktree
remove`); `teardown-check.sh` is no exception.

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

## Follow-ups / known robustness gaps

Logged here deliberately rather than fixed, per an explicit human gate-scope decision — real
shell-robustness-class findings, out of blocking scope for this file's own recipes, but tracked so
they aren't silently lost:

- **Section 6's `open_claims_output=$(bin/claim-ledger.py status)` is a bare call under
  `set -e`, with no `rc=$?` capture.** `claim-ledger.py status` is not purely binary in practice:
  confirmed live that pointing `SM_CLAIM_LEDGER` at a directory instead of a file makes it crash
  with an unhandled `IsADirectoryError` and exit `1`, and the bare, unguarded call aborts the
  whole script right there under `set -euo pipefail` — before the dispatcher's own promised
  human-escalation step (the same step this file's "Strict-mode exit-code discipline" idiom
  already applies to every other command in this recipe) ever runs. Suggested fix: capture via
  `rc_status=0; open_claims_output=$(bin/claim-ledger.py status) || rc_status=$?`, escalate on
  `rc_status != 0`, the identical idiom already applied to `hold.py open` two lines above it in
  this same section.

## Proposed secondmate SKILL.md amendment (HUMAN-OWNED — apply by hand)

**Not yet applied.** This is the exact one-to-two sentence addition a human should paste into
`skills/secondmate/SKILL.md`'s own "Dispatch mechanics — solo and batch" section, acknowledging the
external case without touching that file's existing content:

> An external process outside Claude Code (e.g. Hermes, or any agent with terminal access + a
> scheduler) may hold this top-level dispatcher role instead of an in-session Agent-tool caller —
> see `skills/secondmate-dispatch/SKILL.md` for the OS-process spawn/watchdog/hold contract. Every
> sub-agent-supervisor it spawns remains a fresh Claude Code session running this same SOP
> unchanged.
