#!/usr/bin/env python3
# ponytail: append-only JSONL ledger, fcntl-locked -- same idiom as claim-ledger.py/hold.py. No daemon,
# no heartbeat thread, no sqlite: self-reported checkpoints polled on a schedule, not a liveness oracle.
"""progress-ledger.py -- self-reported progress checkpoints for fan-out sub-agent-supervisors.

Today's Agent-tool background sub-agents give a dispatcher no way to poll their liveness from outside
(verified against Claude Code's own documented behavior) -- if a sub-supervisor dies silently before
ever reaching verify-gate, the dispatcher gets no signal at all. This primitive does not solve that: it
lets each sub-supervisor self-report {task-id, phase, ts} rows at checkpoints in its own SOP, so a
dispatcher polling on a schedule (via the harness's wakeup mechanism, never real-time) can notice a
task-id whose phase hasn't advanced in too long and flag it to a human. Detects STALENESS, not a proven
crash -- a slow-but-alive sub-supervisor looks identical to a dead one until it reports its next
checkpoint. This is a hard platform limitation, not a shortcut deferred here.

  progress-ledger.py record --task-id ID --owner LABEL --phase PHASE  -> appends a checkpoint row.
    [--checked-sha SHA] [--checker-verdict-path PATH] [--batch-id ID]    --checked-sha/--checker-verdict-path
    [--cost N] [--tokens N] [--duration-seconds N]                        are free-form optional extras, meant
    [--still-achievable {yes,no}] [--note TEXT]                          for the terminal `verify_gate_pass`
                                                                           phase (see vocabulary below) so a
                                                                           later batch-close consumer can read
                                                                           them off that one row -- this script
                                                                           does not enforce which phase they're
                                                                           attached to. --batch-id (same bare-
                                                                           identifier charset as --task-id) is the
                                                                           CORRELATION KEY a batch dispatcher
                                                                           assigns once per fan-out and passes on
                                                                           every checkpoint for every task-id in
                                                                           that batch -- it is what lets `ready
                                                                           --batch-id ID` distinguish "ready for
                                                                           THIS batch" from an unrelated batch's
                                                                           (or a single-task-delegation trigger-A
                                                                           task's) own verify_gate_pass row. A
                                                                           task-id's batch-id is IMMUTABLE once
                                                                           established: the FIRST checkpoint for a
                                                                           given task-id that supplies --batch-id
                                                                           at all fixes its binding permanently --
                                                                           a LATER record call for that SAME
                                                                           task-id supplying a DIFFERENT --batch-id
                                                                           is REJECTED outright (nonzero exit, no
                                                                           ledger write); supplying the SAME value
                                                                           again (the normal case -- every
                                                                           checkpoint in one sub-supervisor's own
                                                                           SOP repeats it) is always fine.
                                                                           --cost/--tokens/--duration-seconds are
                                                                           self-reported, per-checkpoint budget
                                                                           numbers (finite, >= 0) -- a free-form
                                                                           caller-defined number, NOT cumulative,
                                                                           and NOT reconciled with bin/log-round.sh's
                                                                           own separate --cost/--duration (a
                                                                           different ledger, a different purpose).
                                                                           --still-achievable {yes,no} is a
                                                                           checkpoint self-estimate -- a plain
                                                                           self-report, not a trained predictor --
                                                                           with zero automated consequence
                                                                           anywhere in this codebase (never read
                                                                           by `stale`/`ready`, never gates
                                                                           anything). --note (optional, capped
                                                                           length, only accepted alongside
                                                                           --still-achievable) is free text
                                                                           explaining that estimate. All five
                                                                           fields are strictly additive: omitted
                                                                           entirely from the written row when not
                                                                           supplied, and rendered by
                                                                           `latest`/`status` only when present.
  progress-ledger.py latest | status                                  -> one line per task-id: its most
                                                                           recently recorded phase/owner/ts
                                                                           (and checked-sha/checker-verdict-path
                                                                           if present).
  progress-ledger.py stale --threshold-seconds N [--task-id ID ...]   -> read-only: for each given --task-id
                                                                           (repeatable; every task-id ever seen
                                                                           in the ledger if none given), reports
                                                                           one JSON line if it has NEVER recorded
                                                                           any progress, or if its latest phase's
                                                                           ts is older than N seconds -- exits 1
                                                                           if anything was reported, 0 otherwise.
                                                                           Never appends. A dispatcher calls this
                                                                           on a `ScheduleWakeup`-driven interval
                                                                           for the exact set of task-ids it fanned
                                                                           out, never continuously. A batch
                                                                           dispatcher also reuses this exact same
                                                                           call, with a SEPARATE (larger) threshold,
                                                                           against task-ids already at the terminal
                                                                           `verify_gate_pass` phase -- since that
                                                                           phase never advances further, `stale`
                                                                           against a batch-close TTL is exactly
                                                                           "ready, awaiting batch close, too long"
                                                                           -- no separate staleness mechanism needed.
  progress-ledger.py ready [--task-id ID ...] [--batch-id ID]          -> read-only: for each given --task-id
                                                                           (repeatable; every task-id ever seen in
                                                                           the ledger if none given), reports one
                                                                           JSON line for each whose LATEST recorded
                                                                           phase is exactly the terminal
                                                                           `verify_gate_pass` -- {"task_id":...,
                                                                           "checked_sha":..., "checker_verdict_path":...,
                                                                           "ts":...} ("checked_sha"/
                                                                           "checker_verdict_path" omitted if never
                                                                           supplied on that row). Always exits 0 --
                                                                           this is a normal informational query, not
                                                                           an error signal (unlike `stale`). Never
                                                                           appends. This is the one query a batch
                                                                           dispatcher needs to collect "all task-ids
                                                                           ready to fold into the next batch close"
                                                                           straight from disk -- combined with
                                                                           `claim-ledger.py status`'s own open-claims
                                                                           list (to exclude anything already merged
                                                                           and released from a prior batch), a
                                                                           dispatcher that crashes and restarts mid-
                                                                           batch can reconstruct the exact same
                                                                           "ready, awaiting batch" set from the two
                                                                           ledgers alone, with no reliance on its own
                                                                           lost in-memory state. --batch-id (omitted
                                                                           by default -- see `record`'s own
                                                                           --batch-id above) restricts the reported
                                                                           task-ids to exactly those BOUND to that
                                                                           batch-id -- matched against each
                                                                           task-id's own immutable, earliest-
                                                                           established binding (never just its
                                                                           terminal row), and a task-id whose own
                                                                           row history is internally inconsistent
                                                                           is excluded outright regardless of
                                                                           whether its terminal row happens to
                                                                           match. Omitting --batch-id keeps today's
                                                                           behavior exactly (every ready task-id,
                                                                           unfiltered) -- this is how trigger-A
                                                                           usage is unaffected.
  progress-ledger.py selfcheck                                        -> asserts the fold + drives the real
                                                                           CLI paths against a scratch ledger.

HONEST LIMITATION of --batch-id (do not overclaim beyond this): the immutability guard above closes batch-id
DRIFT for one task-id over its own lifetime (e.g. a stale/reused task-id string whose earlier history
belongs to a different, older batch) -- it does NOT, and structurally CANNOT, prevent two GENUINELY
DIFFERENT, freshly-claimed task-ids from two INDEPENDENT, uncoordinated dispatcher PROCESSES from both
legitimately, self-consistently binding to the identical --batch-id string by coincidence (this ledger has
no way to distinguish "intentionally co-batched" from "accidentally collided" for two task-ids that are each
individually self-consistent). That would require a distributed uniqueness registry -- explicitly out of
scope (see SKILL.md's fan-out section: "no 1000-task hardening... the cap is an explicit 10, hard, not
tunable"). The PRACTICAL mitigation is SKILL.md's own guidance to mint --batch-id from a UUID rather than a
timestamp, making an accidental cross-process collision negligible, not impossible.

Suggested phase vocabulary (free text, NOT a closed enum -- a sub-supervisor may record any phase string
that fits [A-Za-z0-9_-]{1,64} -- but SKILL.md's fan-out SOP records exactly these, at exactly these
checkpoints, so `stale`'s threshold semantics stay meaningful across every task-id):
  claimed            -- immediately after bin/claim-ledger.py claim succeeds
  maker_started      -- immediately after its maker (Claude/pi worktree) begins running
  checker_round      -- immediately after each checker round completes (recorded once per round; ts alone
                         tells the dispatcher "still moving", no round number needed for staleness)
  verify_gate_pass   -- the TERMINAL phase, once verify-gate has passed -- the one a later consumer filters
                         for, reading its --checked-sha/--checker-verdict-path off this exact row.

No auto-restart, no auto-`--steal`, no attempt at real-time detection -- exactly like claim-ledger.py's own
"no liveness/heartbeat/TTL" stance, for the same reason: this script has no reliable way to know whether a
sub-supervisor that stopped reporting is dead, wedged, or just slow, and a raw OS PID means nothing for an
Agent-tool background agent. `stale` only ever reports; whoever calls it decides what to do, and per
SKILL.md's fan-out SOP, that action is always "surface to the human verbatim", never an automatic recovery.

Ledger path resolution is IDENTICAL to claim-ledger.py's own (first match wins), so a dispatcher and every
sub-supervisor it launches -- each in its own linked worktree -- agree on one shared file without either
side configuring anything:
  1. $SM_PROGRESS_LEDGER, if set -- used exactly as given.
  2. $SM_LOOP_STATE/progress.jsonl, if $SM_LOOP_STATE is set.
  3. Otherwise, anchored to `git rev-parse --git-common-dir`'s parent (or the common-dir itself for a bare
     repo or a submodule -- see claim-ledger.py's own docstring for the full rationale, copied verbatim here
     since it's the same shared-worktree problem). Falls back to a CWD-relative `.secondmate/progress.jsonl`
     (with a loud stderr warning) only if not inside a git repo at all.

This script never touches claim-ledger.py's own ledger, schema, or event types -- it is a separate file,
a separate ledger, a separate concern (progress checkpoints, not claim ownership).
"""
import json, sys, os, time, re, math, subprocess, argparse, pathlib, contextlib, io, tempfile, shutil
try:
    import fcntl
except ImportError:  # non-Unix (e.g. Windows) -> best-effort, no locking
    fcntl = None

_SCRIPT_PATH = os.path.abspath(__file__)

TERMINAL_PHASE = "verify_gate_pass"  # the phase a later batch-close consumer filters for (not enforced here)


def _default_ledger_path():
    """Identical resolution to claim-ledger.py's _default_ledger_path -- see that script's docstring for
    the full bare-repo/submodule rationale. Copied rather than imported: every bin/ script here is a
    standalone single-file CLI by this repo's own convention (no shared internal module)."""
    if os.environ.get("SM_PROGRESS_LEDGER"):
        return pathlib.Path(os.environ["SM_PROGRESS_LEDGER"])
    if os.environ.get("SM_LOOP_STATE"):
        return pathlib.Path(os.environ["SM_LOOP_STATE"]) / "progress.jsonl"
    try:
        out = subprocess.run(["git", "rev-parse", "--git-common-dir"], capture_output=True, text=True)
        if out.returncode == 0 and out.stdout.strip():
            common_dir = pathlib.Path(out.stdout.strip())
            if not common_dir.is_absolute():
                common_dir = pathlib.Path.cwd() / common_dir
            common_dir = common_dir.resolve()
            anchor = common_dir if common_dir.name != ".git" else common_dir.parent
            return anchor / ".secondmate" / "progress.jsonl"
    except OSError:
        pass
    sys.stderr.write(
        "WARNING: progress-ledger.py could not resolve a git-common-dir (not inside a git repo, or git "
        "not found) -- falling back to a CWD-relative ./.secondmate/progress.jsonl, which will NOT be "
        "shared across other worktrees/CWDs. Set SM_PROGRESS_LEDGER to a shared path.\n")
    return pathlib.Path(".secondmate") / "progress.jsonl"


LEDGER = _default_ledger_path()
_BAD = 0  # count of malformed/incomplete ledger lines seen by the last _recs()

# same bare-identifier posture as claim-ledger.py's _TASK_ID_RE / --scope KIND:KEY -- no path separators,
# no null bytes, no empty string, bounded length.
_TASK_ID_RE = re.compile(r"\A[A-Za-z0-9_-]{1,128}\Z")
_PHASE_RE = re.compile(r"\A[A-Za-z0-9_-]{1,64}\Z")


def _valid_task_id(task_id):
    return isinstance(task_id, str) and bool(_TASK_ID_RE.match(task_id))


def _valid_phase(phase):
    return isinstance(phase, str) and bool(_PHASE_RE.match(phase))


NOTE_MAX_LEN = 500  # bounded free-text cap for --note, same "bounded length" posture as every other field


def _valid_budget_number(x):
    # same finite guard bin/log-round.sh's own _is_finite_number applies to --cost/--duration (nan/inf
    # are valid floats but not valid JSON), plus a non-negative floor: a cost/token/duration count can
    # never be negative, which log-round.sh's own precedent does not need to enforce for its freeform use.
    if isinstance(x, bool):
        return False
    if isinstance(x, int):
        # CONFIRMED BUG (checker, same pattern already fixed in bin/pane-reaper.py's
        # _valid_positive_number): calling math.isfinite(x) on a native Python int implicitly converts
        # it to a float first -- for an arbitrarily large int (e.g. 10**10000) that conversion itself
        # raises OverflowError ("int too large to convert to float"), an UNCAUGHT exception instead of a
        # clean accept/reject. Today's CLI only ever passes this function a float (argparse's own
        # type=float on --cost/--tokens/--duration-seconds), but the function's own signature explicitly
        # accepts int too, so any direct/reused caller passing a native int must not crash. A native int
        # has no "infinite" representation at all (arbitrary precision, never nan/inf), so math.isfinite
        # is unnecessary and actively harmful here: just compare directly.
        return x >= 0
    if isinstance(x, float):
        return math.isfinite(x) and x >= 0
    return False


def _valid_ts(ts):
    # a "ts" that isn't a string in this script's own written shape can never be folded into an epoch by
    # _ts_to_epoch (stale would otherwise crash on time.strptime's ValueError) -- same posture as
    # claim-ledger.py treating a non-token-shaped "token" as malformed rather than a valid open claim: a
    # row this script itself could never have produced is corruption, not a checkpoint.
    if not isinstance(ts, str):
        return False
    try:
        time.strptime(ts, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return False
    return True


def _recs():
    # tolerant parse: skip malformed/incomplete lines but COUNT them (same discipline as hold.py /
    # claim-ledger.py), so `latest`/`stale` warn instead of a partial write silently hiding a checkpoint.
    global _BAD
    _BAD = 0
    recs = []
    if not LEDGER.exists():
        return recs
    for line in LEDGER.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except (ValueError, RecursionError):
            # CONFIRMED BUG (checker): a deeply-nested but syntactically valid JSON line (e.g. ~1100
            # levels of nested arrays) raises RecursionError, not ValueError -- the same class already
            # fixed in this script's own _ts_to_epoch/stale and in pane-reaper.py's _herdr_json. Must be
            # treated as any other malformed/unparseable line: counted in _BAD, skipped, never crash the
            # whole read.
            _BAD += 1; continue
        valid = (isinstance(o, dict) and o.get("ev") == "progress"
                 and isinstance(o.get("task_id"), str) and isinstance(o.get("owner"), str)
                 and isinstance(o.get("phase"), str) and _valid_ts(o.get("ts")))
        if valid:
            recs.append(o)
        else:
            _BAD += 1
    return recs


def _append(rec):
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    with LEDGER.open("a") as f:
        f.write(json.dumps(rec) + "\n")


@contextlib.contextmanager
def _ledger_lock():
    # Same fcntl idiom as hold.py/claim-ledger.py's _ledger_lock(): serialize concurrent appends with an
    # exclusive OS lock on a sibling .lock file, so ledger append order under the lock IS the true
    # chronological order (this is what `latest`'s "last matching record wins" relies on).
    if fcntl is None:
        yield; return
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    with open(str(LEDGER) + ".lock", "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def latest_by_task(recs=None):
    """Fold the ledger to {task_id: most-recently-appended progress row}. Ledger append order (under the
    lock) IS chronological order -- the same precedent claim-ledger.py's steal-TOCTOU test establishes --
    so 'last occurrence in file order' is exactly 'most recent checkpoint', no ts comparison needed here."""
    recs = _recs() if recs is None else recs
    latest = {}
    for r in recs:
        latest[r["task_id"]] = r
    return latest


def _binding_batch_id(task_id, recs):
    """The batch-id a task-id is immutably BOUND to: the value on the EARLIEST row (ledger append order
    -- the true chronological order under this script's own fcntl lock, same precedent latest_by_task's
    own docstring relies on) for that task-id that carries a --batch-id at all -- established once, at
    that task-id's first checkpoint to declare one (per SKILL.md's fan-out SOP, that is its `claimed`
    checkpoint, the earliest in the documented phase sequence), and enforced immutable afterward by
    `record`'s own write-time guard (see that call site) -- never re-specifiable from a later checkpoint.

    Returns (binding, consistent): `binding` is None if the task-id never recorded any --batch-id at
    all. `consistent` is False if some LATER row for the SAME task-id disagrees with the binding --
    defense in depth against a row `record`'s own guard never saw (a hand-edited ledger line, or one
    written by an older version of this script) -- `ready --batch-id` must never trust a task-id's
    terminal row alone; an inconsistent task-id is excluded regardless of what its terminal row says,
    even if that terminal row happens to nominally match the query."""
    binding = None
    consistent = True
    for r in recs:
        if r.get("task_id") != task_id:
            continue
        bid = r.get("batch_id")
        if not bid:
            continue
        if binding is None:
            binding = bid
        elif bid != binding:
            consistent = False
    return binding, consistent


def _all_task_ids():
    """Every task_id ever mentioned in a progress row, scanned directly and defensively -- even from a
    row that fails _recs()'s stricter validation (e.g. an unparseable ts). Used only to build the
    candidate set for a whole-ledger `stale` scan (no --task-id given): without this, a task-id whose
    ONLY checkpoint is corrupted would be invisible to latest_by_task's fold and silently vanish from
    the watchdog's view instead of surfacing as no_progress_recorded, exactly the false-negative a
    staleness watchdog exists to avoid."""
    ids = set()
    if not LEDGER.exists():
        return ids
    for line in LEDGER.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except (ValueError, RecursionError):
            # CONFIRMED BUG (checker, round 9): a deeply-nested but syntactically valid JSON line (e.g.
            # ~1100 levels of nested arrays) raises RecursionError, not ValueError -- the same class
            # already fixed in this script's own _recs() (round 8). This is a SEPARATE json.loads loop
            # over the same ledger file, so round 8's fix did not cover it; a whole-ledger `stale`/`ready`
            # scan (no --task-id) still crashed via this path.
            continue
        if isinstance(o, dict) and o.get("ev") == "progress" and isinstance(o.get("task_id"), str):
            ids.add(o["task_id"])
    return ids


def _ts_to_epoch(ts):
    # ts is always written by this script's own time.strftime("%Y-%m-%dT%H:%M:%S") (local time, matching
    # claim-ledger.py/hold.py) -- parse it back with the same local-time interpretation via mktime.
    # CONFIRMED BUG (checker round 4): a ts that passes _valid_ts's own strptime-based format check fine
    # (e.g. "0001-01-01T00:00:00") can still be numerically out of time.mktime's representable range,
    # raising an uncaught OverflowError -- same root-cause class already fixed in bin/pane-reaper.py's own
    # _ts_to_epoch. Returns None on failure so callers (e.g. `stale`) can treat the row as unusable/corrupt
    # rather than crash, the same tolerant posture _recs() already applies to other malformed rows.
    try:
        return time.mktime(time.strptime(ts, "%Y-%m-%dT%H:%M:%S"))
    except (OverflowError, OSError, ValueError):
        return None


def _run(argv):
    # selfcheck helper: invoke the REAL main() and capture the result, matching claim-ledger.py's own
    # _run helper -- never reimplement main()'s logic in the selfcheck itself.
    out = io.StringIO()
    code = 0
    exc = None
    try:
        with contextlib.redirect_stdout(out):
            main(argv)
    except SystemExit as e:
        code = 1
        exc = e.code
    return code, out.getvalue().strip(), exc


def _selfcheck_live():
    global LEDGER
    orig_ledger = LEDGER
    tmpdir = tempfile.mkdtemp(prefix="progress-ledger-selfcheck-")
    LEDGER = pathlib.Path(tmpdir) / "progress.jsonl"
    try:
        # basic record -> visible in latest.
        code, out, _ = _run(["record", "--task-id", "t1", "--owner", "sm-t1", "--phase", "claimed"])
        assert code == 0, "a valid record must succeed"
        code, out, _ = _run(["latest"])
        assert code == 0 and "t1" in out and "phase=claimed" in out and "owner=sm-t1" in out, (
            "latest must show the just-recorded checkpoint")

        # a second, later phase for the same task-id becomes the new latest -- the first is not lost from
        # the ledger, just superseded in the fold.
        code, _, _ = _run(["record", "--task-id", "t1", "--owner", "sm-t1", "--phase", "maker_started"])
        assert code == 0
        code, out, _ = _run(["latest"])
        assert "phase=maker_started" in out, "latest must reflect the most recently recorded phase"
        assert len([r for r in _recs() if r["task_id"] == "t1"]) == 2, (
            "recording a new phase must not overwrite or remove the prior checkpoint row")

        # --checked-sha / --checker-verdict-path are optional extras, rendered only when present --
        # same "omit entirely when absent" convention as claim-ledger.py's scope/operation.
        code, out, _ = _run(["latest"])
        assert "checked_sha=" not in out, "checked_sha must be omitted when never supplied"
        code, _, _ = _run(["record", "--task-id", "t1", "--owner", "sm-t1", "--phase", TERMINAL_PHASE,
                            "--checked-sha", "deadbeef", "--checker-verdict-path", "/tmp/v.json"])
        assert code == 0
        code, out, _ = _run(["latest"])
        assert f"phase={TERMINAL_PHASE}" in out and "checked_sha=deadbeef" in out \
            and "checker_verdict_path=/tmp/v.json" in out, (
            "latest must render checked-sha/checker-verdict-path when present on the latest row")

        # ready: t1 is at the terminal phase (verify_gate_pass, set above) -- must be reported, carrying
        # its checked-sha/checker-verdict-path off that exact row.
        code, out, _ = _run(["ready", "--task-id", "t1"])
        assert code == 0 and '"task_id": "t1"' in out and '"checked_sha": "deadbeef"' in out, (
            "ready must report a task-id whose latest phase is the terminal phase, with its checked-sha")

        # ready: a task-id whose latest phase is NOT terminal (e.g. still at maker_started) must not be
        # reported, even though it has recorded progress.
        code, _, _ = _run(["record", "--task-id", "t3", "--owner", "sm-t3", "--phase", "maker_started"])
        assert code == 0
        code, out, _ = _run(["ready", "--task-id", "t3"])
        assert code == 0 and out == "", "ready must not report a task-id stuck at a non-terminal phase"

        # ready: a task-id with no progress at all must not be reported (never crash on a missing row).
        code, out, _ = _run(["ready", "--task-id", "never-recorded-ready"])
        assert code == 0 and out == "", "ready must not report a task-id with zero progress rows"

        # ready never appends -- it's read-only, like `stale`.
        pre_len = len(_recs())
        _run(["ready", "--task-id", "t1"])
        assert len(_recs()) == pre_len, "ready must never append to the ledger"

        # ready with no --task-id at all scans every known task-id, reporting only those at the terminal
        # phase -- t1 (terminal) yes, t3 (maker_started) no.
        code, out, _ = _run(["ready"])
        assert code == 0 and '"task_id": "t1"' in out and '"task_id": "t3"' not in out, (
            "ready with no --task-id must scan every known task-id but only report terminal-phase ones")

        # --batch-id correlation: a restarted batch dispatcher must be able to tell "ready for THIS
        # batch" apart from an unrelated batch's (or a trigger-A task's) own verify_gate_pass row. t1
        # (above) was recorded with no --batch-id at all (the trigger-A/no-filter usage); t4 and t5 below
        # are recorded at the terminal phase under two DIFFERENT batch-ids.
        code, _, _ = _run(["record", "--task-id", "t4", "--owner", "sm-t4", "--phase", TERMINAL_PHASE,
                            "--checked-sha", "t4sha", "--batch-id", "batchA"])
        assert code == 0
        code, _, _ = _run(["record", "--task-id", "t5", "--owner", "sm-t5", "--phase", TERMINAL_PHASE,
                            "--checked-sha", "t5sha", "--batch-id", "batchB"])
        assert code == 0

        # `latest` renders batch_id when present, omits it when absent -- same "only when given"
        # convention as checked_sha/checker_verdict_path.
        code, out, _ = _run(["latest"])
        assert "[t4]" in out and "batch_id=batchA" in out, "latest must render batch_id when present"
        assert "[t1]" in out, "sanity: t1 must still appear in latest"
        assert "batch_id=" not in out.split("[t1]")[1].split("\n")[0], (
            "latest must omit batch_id entirely for a row that never supplied one")

        # ready --batch-id batchA reports ONLY t4 -- never t5 (a different batch-id) and never t1 (no
        # batch-id at all, i.e. an unrelated trigger-A task or a row predating this correlation key).
        code, out, _ = _run(["ready", "--task-id", "t1", "--task-id", "t4", "--task-id", "t5",
                              "--batch-id", "batchA"])
        assert code == 0, "ready --batch-id must still exit 0 (an informational query, not an error signal)"
        assert '"task_id": "t4"' in out, "ready --batch-id must report the task-id recorded under that batch-id"
        assert '"task_id": "t5"' not in out, "ready --batch-id must NOT report a different batch-id's task-id"
        assert '"task_id": "t1"' not in out, "ready --batch-id must NOT report a task-id with no batch-id at all"

        # omitting --batch-id entirely must keep TODAY's no-filter behavior exactly -- every ready
        # task-id regardless of batch-id, so trigger-A's existing no-filter usage is unaffected.
        code, out, _ = _run(["ready", "--task-id", "t1", "--task-id", "t4", "--task-id", "t5"])
        assert code == 0
        assert '"task_id": "t1"' in out and '"task_id": "t4"' in out and '"task_id": "t5"' in out, (
            "omitting --batch-id must report every ready task-id regardless of its own batch-id")

        # --batch-id validation on `record` matches --task-id's own bare-identifier posture.
        for bad in ("", "bad id", "a/b", "a" * 129):
            code, _, _ = _run(["record", "--task-id", "t6", "--owner", "o", "--phase", "claimed",
                                "--batch-id", bad])
            assert code != 0, f"invalid --batch-id {bad!r} must be rejected"

        # --batch-id IMMUTABILITY (write-time enforcement): a task-id's batch-id is fixed at its
        # earliest checkpoint that declares one. Repeating the SAME value on every later checkpoint
        # (the normal SOP) is always fine; supplying a DIFFERENT value for that SAME task-id must be
        # rejected outright (nonzero exit, no ledger write) -- "rejecting the second [conflicting]
        # registration", the structural half of this fix. This closes batch-id DRIFT/reuse for one
        # task-id's own lifetime (e.g. a stale task-id string later reused under a different, unrelated
        # batch) -- a real, different risk from the cross-task-id collision case tested below.
        code, _, _ = _run(["record", "--task-id", "reuse-x", "--owner", "sm-reuse-x", "--phase", "claimed",
                            "--batch-id", "batchOLD"])
        assert code == 0, "first-ever --batch-id for a task-id must succeed"
        code, _, _ = _run(["record", "--task-id", "reuse-x", "--owner", "sm-reuse-x",
                            "--phase", "maker_started", "--batch-id", "batchOLD"])
        assert code == 0, "repeating the SAME --batch-id for the same task-id must always succeed"
        pre_len = len(_recs())
        code, _, exc = _run(["record", "--task-id", "reuse-x", "--owner", "sm-reuse-x",
                              "--phase", TERMINAL_PHASE, "--batch-id", "batchNEW"])
        assert code != 0, "rebinding an already-bound task-id to a DIFFERENT --batch-id must be rejected"
        assert "batchOLD" in str(exc) and "batchNEW" in str(exc), (
            "the rejection should name both the existing binding and the rejected new value")
        assert len(_recs()) == pre_len, "a rejected rebind attempt must not append any record"
        # the task-id's binding stays exactly what it was -- unaffected by the rejected attempt.
        code, out, _ = _run(["latest"])
        assert "batch_id=batchOLD" in out.split("[reuse-x]")[1].split("\n")[0], (
            "the task-id's binding must remain batchOLD, untouched by the rejected rebind attempt")

        # HONEST LIMITATION, exercised directly (the exact checker repro): two GENUINELY DIFFERENT,
        # freshly-claimed task-ids ("old" and "new", from what would be two independent dispatcher
        # batches) both legitimately, self-consistently bind to the IDENTICAL --batch-id "same" -- a
        # realistic accidental collision if that id were timestamp-derived (which is exactly why
        # SKILL.md now instructs minting it from a UUID instead). Neither task-id's own row history is
        # internally inconsistent, so the immutability guard above -- which only rejects a task-id
        # trying to CHANGE ITS OWN prior binding -- has nothing to reject for either of them; this
        # ledger has no way to distinguish "intentionally co-batched" from "accidentally collided" for
        # two independently-fresh, self-consistent task-ids without a distributed uniqueness registry
        # (explicitly out of scope). `ready --batch-id same` STILL reports both -- this is the accepted,
        # honestly-documented residual gap the UUID recommendation mitigates PRACTICALLY, never
        # structurally. This assertion exists so that gap is pinned down and visible, not silently
        # assumed fixed.
        for tid, owner in (("old", "sm-old"), ("new", "sm-new")):
            for phase in ("claimed", "maker_started", "checker_round", TERMINAL_PHASE):
                code, _, _ = _run(["record", "--task-id", tid, "--owner", owner, "--phase", phase,
                                    "--batch-id", "same"])
                assert code == 0
        code, out, _ = _run(["ready", "--task-id", "old", "--task-id", "new", "--batch-id", "same"])
        assert code == 0
        assert '"task_id": "old"' in out and '"task_id": "new"' in out, (
            "documented residual limitation: two independently-fresh, self-consistent task-ids that "
            "coincidentally share a --batch-id are NOT structurally distinguishable by this ledger alone")

        # Defense in depth: `ready --batch-id` must exclude a task-id whose OWN row history is
        # internally INCONSISTENT (a row `record`'s write-time guard never saw -- e.g. a hand-edited or
        # legacy ledger line) -- excluded regardless of whether its terminal row happens to nominally
        # match the query, never trusting the terminal row alone. Appended directly (bypassing
        # `record`'s own guard) to simulate exactly that.
        _append({"ev": "progress", "task_id": "corrupt-x", "owner": "o", "phase": "claimed",
                  "ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "batch_id": "batchA"})
        _append({"ev": "progress", "task_id": "corrupt-x", "owner": "o", "phase": TERMINAL_PHASE,
                  "ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "batch_id": "batchB"})
        code, out, _ = _run(["ready", "--task-id", "corrupt-x", "--batch-id", "batchB"])
        assert code == 0 and '"task_id": "corrupt-x"' not in out, (
            "an inconsistent task-id must be excluded even when queried by its OWN (later, disagreeing) "
            "terminal batch-id")
        code, out, _ = _run(["ready", "--task-id", "corrupt-x", "--batch-id", "batchA"])
        assert code == 0 and '"task_id": "corrupt-x"' not in out, (
            "an inconsistent task-id must be excluded even when queried by its OWN earliest/binding "
            "batch-id -- an inconsistent history is never trusted for ANY match")

        # task-id / phase validation, matching claim-ledger.py's bare-identifier posture.
        for bad in ("", "../etc", "a/b", "a\0b", "bad id", "a" * 129, "ok\n"):
            code, _, _ = _run(["record", "--task-id", bad, "--owner", "o", "--phase", "claimed"])
            assert code != 0, f"invalid --task-id {bad!r} must be rejected"
        for bad_phase in ("", "bad phase", "a" * 65, "../x"):
            code, _, _ = _run(["record", "--task-id", "t2", "--owner", "o", "--phase", bad_phase])
            assert code != 0, f"invalid --phase {bad_phase!r} must be rejected"
        code, _, _ = _run(["record", "--task-id", "t2", "--owner", "", "--phase", "claimed"])
        assert code != 0, "empty --owner must be rejected"

        # stale: a task-id recorded just now, with a generous threshold, is never stale.
        code, out, exc = _run(["stale", "--threshold-seconds", "3600", "--task-id", "t1"])
        assert exc == 0 and out == "", "a just-recorded task-id must not be reported stale"

        # stale: a task-id with NO progress rows at all must be reported (a sub-supervisor that died
        # before ever recording its first checkpoint looks exactly like this).
        code, out, exc = _run(["stale", "--threshold-seconds", "3600", "--task-id", "never-recorded"])
        assert exc == 1, "a task-id with zero progress rows must be reported by stale"
        assert '"task_id": "never-recorded"' in out and '"status": "no_progress_recorded"' in out

        # stale: backdate a checkpoint (write the raw ledger line directly, like hold.py's own selfcheck
        # backdates a hold) far enough in the past that a small threshold reports it, a huge one does not.
        old_ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - 7200))
        with LEDGER.open("a") as f:
            f.write(json.dumps({"ev": "progress", "task_id": "old", "owner": "sm-old", "phase": "claimed",
                                 "ts": old_ts}) + "\n")
        code, out, exc = _run(["stale", "--threshold-seconds", "60", "--task-id", "old"])
        assert exc == 1, "a checkpoint older than the threshold must be reported stale"
        assert '"task_id": "old"' in out and '"status": "stale"' in out and '"phase": "claimed"' in out
        code, out, exc = _run(["stale", "--threshold-seconds", "36000", "--task-id", "old"])
        assert exc == 0 and out == "", "the same checkpoint must NOT be stale against a huge threshold"

        # regression: a row with an unparseable "ts" (e.g. hand-corrupted, or a future format-change bug)
        # must NOT crash `stale` -- it must be treated as malformed/excluded, same as any other corrupt
        # row, so the task-id it belongs to folds to "no progress recorded" rather than an uncaught
        # exception silently disabling the dispatcher's only staleness signal.
        bad_before = _BAD
        with LEDGER.open("a") as f:
            f.write(json.dumps({"ev": "progress", "task_id": "badts", "owner": "o", "phase": "claimed",
                                 "ts": "bogus"}) + "\n")
        assert "badts" not in latest_by_task(), "a row with an unparseable ts must not fold into latest"
        code, out, exc = _run(["stale", "--threshold-seconds", "1", "--task-id", "badts"])
        assert exc == 1, "stale must not crash on an unparseable ts -- it must report the task-id instead"
        assert '"task_id": "badts"' in out and '"status": "no_progress_recorded"' in out, (
            "a task-id whose only row has an unparseable ts must be reported no_progress_recorded")
        _recs()  # refresh _BAD as a side effect
        assert _BAD > bad_before, "an unparseable-ts row must be counted as malformed (_BAD)"

        # CONFIRMED BUG (checker round 4): a row whose "ts" is SYNTACTICALLY valid (passes _valid_ts's
        # own strptime-based format check, e.g. "0001-01-01T00:00:00") but numerically out of
        # time.mktime's representable range previously crashed `stale` with an uncaught OverflowError --
        # unlike "badts" above, this row DOES fold into latest_by_task (it's format-valid), so the crash
        # happened inside stale's own age computation, not _recs()'s validation. Must be treated as
        # unusable/corrupt for staleness purposes -- excluded from hits, never a crash.
        with LEDGER.open("a") as f:
            f.write(json.dumps({"ev": "progress", "task_id": "extreme-ts-task", "owner": "o",
                                 "phase": "claimed", "ts": "0001-01-01T00:00:00"}) + "\n")
        assert "extreme-ts-task" in latest_by_task(), (
            "an extreme-but-format-valid ts row IS format-valid and must fold into latest_by_task")
        code, out, exc = _run(["stale", "--threshold-seconds", "1", "--task-id", "extreme-ts-task"])
        assert exc in (0, 1), f"stale must never crash on an extreme-but-format-valid ts: {out!r}"
        assert '"task_id": "extreme-ts-task"' not in out, (
            f"a task-id whose latest row has an unconvertible ts must never be reported by stale "
            f"(neither stale nor no_progress_recorded -- it has a row, just an unusable one): {out!r}")

        # stale with no --task-id at all considers every task-id ever seen in the ledger -- INCLUDING one
        # whose only row failed the ts-shape fold above ("badts"), which must still surface as
        # no_progress_recorded rather than silently vanish from a whole-ledger scan just because its one
        # row never made it into latest_by_task.
        code, out, exc = _run(["stale", "--threshold-seconds", "60"])
        assert exc == 1 and '"task_id": "old"' in out and '"task_id": "t1"' not in out, (
            "omitting --task-id must scan every known task-id, reporting only the actually-stale ones")
        assert '"task_id": "badts", "status": "no_progress_recorded"' in out, (
            "a whole-ledger scan must still report a task-id whose only row failed ts validation")

        # CONFIRMED BUG (checker): a deeply-nested but SYNTACTICALLY VALID JSON line stored directly in
        # the ledger file (e.g. ~1100 levels of nested arrays) raises an uncaught RecursionError from
        # json.loads, not ValueError -- the existing `except ValueError` in _recs()'s own parse loop does
        # not catch it, so the whole read (and therefore `stale`/`latest`) crashed instead of treating the
        # one line as malformed like any other unparseable row. Placed last (after every whole-ledger
        # `--task-id`-omitted scan above) since this corrupt line, once appended, persists in the shared
        # ledger for the rest of this function -- it must never again crash a later full scan either, but
        # there are none left after this point in this test function.
        bad_before = _BAD
        with LEDGER.open("a") as f:
            f.write("[" * 1100 + "]" * 1100 + "\n")
        code, out, exc = _run(["stale", "--threshold-seconds", "1", "--task-id", "whatever"])
        assert exc in (0, 1), (
            f"a deeply-nested-but-valid JSON ledger line must never crash stale with a RecursionError: {out!r}")
        _recs()  # refresh _BAD as a side effect
        assert _BAD > bad_before, "a deeply-nested JSON ledger line must be counted as malformed (_BAD)"

        # `stale` never appends -- it's read-only, like claim-ledger.py's own `conflicts`.
        pre_len = len(_recs())
        _run(["stale", "--threshold-seconds", "1", "--task-id", "t1"])
        assert len(_recs()) == pre_len, "stale must never append to the ledger"

        # Budget-aware checkpoint fields (--cost/--tokens/--duration-seconds/--still-achievable/--note):
        # THE single most important invariant -- a record call that omits all five new flags must
        # produce output byte-for-byte identical to pre-change behavior. "nofields" below never supplies
        # any of them.
        code, out, _ = _run(["record", "--task-id", "nofields", "--owner", "sm-nofields", "--phase", "claimed"])
        assert code == 0
        # record's own success message, not just latest's later rendering, must match legacy output
        # exactly for a no-new-flags call -- CONFIRMED TEST GAP (checker, round 1): the prior version of
        # this selfcheck never asserted record's own stdout at all, so an accidental mutation to that
        # print (e.g. appending stray text) would have gone undetected.
        assert out == "recorded nofields phase=claimed", (
            f"record's own success message for a no-new-flags call must match legacy output exactly: {out!r}")
        r = latest_by_task()["nofields"]
        expected_line = f"[nofields] phase=claimed owner=sm-nofields ts={r['ts']}"
        code, out, _ = _run(["latest"])
        actual_line = [l for l in out.splitlines() if l.startswith("[nofields]")][0]
        assert actual_line == expected_line, (
            f"a record omitting all 5 new fields must render identically to pre-change behavior: "
            f"got {actual_line!r}, expected {expected_line!r}")
        for key in ("cost", "tokens", "duration_seconds", "still_achievable", "note"):
            assert key not in r, f"{key} must be entirely absent from the written row when not supplied"

        # round-trip: all five fields present (including cost=0, a falsy-but-valid value) render on
        # latest/status, and are stored verbatim.
        code, _, _ = _run(["record", "--task-id", "budgetrow", "--owner", "sm-budget", "--phase", "checker_round",
                            "--cost", "0", "--tokens", "1500", "--duration-seconds", "42.5",
                            "--still-achievable", "yes", "--note", "on track"])
        assert code == 0, "a record call with all 5 new fields must succeed"
        code, out, _ = _run(["latest"])
        line = [l for l in out.splitlines() if l.startswith("[budgetrow]")][0]
        assert "cost=0.0" in line and "tokens=1500.0" in line and "duration_seconds=42.5" in line \
            and "still_achievable=yes" in line and "note='on track'" in line, (
            f"latest must render all 5 new fields when present: {line!r}")

        # rejection: non-finite/negative numeric fields, and bad --still-achievable, must all be rejected.
        # "--flag=value" form (not separate argv tokens) sidesteps argparse's own "-inf looks like an
        # unknown option, not a value" ambiguity -- irrelevant to what this script itself validates.
        # CONFIRMED TEST GAP (checker, round 1): the prior version of this loop only exercised
        # nan/inf/-inf for --cost, not for --tokens/--duration-seconds (the validator already rejected
        # all three correctly -- this closes the missing REGRESSION coverage, symmetric across all three
        # numeric fields so a future regression in any one of them would be caught).
        for flag in ("--cost", "--tokens", "--duration-seconds"):
            for bad in ("-1", "nan", "inf", "-inf"):
                combined = f"{flag}={bad}"
                code, _, _ = _run(["record", "--task-id", "badnum", "--owner", "o", "--phase", "claimed", combined])
                assert code != 0, f"{combined!r} must be rejected"
        code, _, _ = _run(["record", "--task-id", "badchoice", "--owner", "o", "--phase", "claimed",
                            "--still-achievable", "maybe"])
        assert code != 0, "--still-achievable must reject a value outside {yes,no}"

        # --note is only valid alongside --still-achievable.
        code, _, _ = _run(["record", "--task-id", "noteonly", "--owner", "o", "--phase", "claimed",
                            "--note", "orphan note"])
        assert code != 0, "--note without --still-achievable must be rejected"

        # --note is length-capped.
        code, _, _ = _run(["record", "--task-id", "longnote", "--owner", "o", "--phase", "claimed",
                            "--still-achievable", "no", "--note", "x" * (NOTE_MAX_LEN + 1)])
        assert code != 0, "--note over the length cap must be rejected"
        code, _, _ = _run(["record", "--task-id", "longnote", "--owner", "o", "--phase", "claimed",
                            "--still-achievable", "no", "--note", "x" * NOTE_MAX_LEN])
        assert code == 0, "--note exactly at the length cap must be accepted"

        # `stale`/`ready` byte-for-byte unaffected: a row carrying the new budget fields must produce the
        # exact same stale/ready shape as a row that never used them -- the new fields must never leak
        # into either query's output.
        code, _, _ = _run(["record", "--task-id", "budgetrow", "--owner", "sm-budget", "--phase", TERMINAL_PHASE,
                            "--checked-sha", "cafef00d", "--cost", "3.3", "--tokens", "999",
                            "--duration-seconds", "10", "--still-achievable", "no", "--note", "slipping"])
        assert code == 0
        code, out, _ = _run(["ready", "--task-id", "budgetrow"])
        assert code == 0 and '"task_id": "budgetrow"' in out and '"checked_sha": "cafef00d"' in out, (
            "ready must still report a terminal-phase row that happens to carry budget fields")
        for key in ("cost", "tokens", "duration_seconds", "still_achievable", "note"):
            assert f'"{key}"' not in out, f"ready's output must never include {key!r} -- stale/ready stay unaware of it"
        code, out, exc = _run(["stale", "--threshold-seconds", "3600", "--task-id", "budgetrow"])
        assert exc == 0 and out == "", "stale's threshold filtering must be unaffected by a row carrying budget fields"

        # status must warn (not silently hide) when the ledger has malformed lines.
        with LEDGER.open("a") as f:
            f.write("not json at all\n")
        code, out, _ = _run(["latest"])
        assert code == 0 and "malformed" in out.lower(), "latest must surface malformed-line corruption"
    finally:
        LEDGER = orig_ledger
        shutil.rmtree(tmpdir, ignore_errors=True)


def _selfcheck_stale_scan_sees_corrupted_only_task():
    # Round-2 regression, isolated: a ledger containing ONLY a malformed-ts row for some task-id (no
    # other row, valid or otherwise, for anything) must still surface that task-id as
    # no_progress_recorded on a whole-ledger `stale` scan (no --task-id given) -- not exit 0/silent. The
    # earlier bug derived the whole-ledger candidate set from latest_by_task's keys alone, which excludes
    # any row that failed the ts-shape fold, so a task-id whose ONLY checkpoint was corrupted vanished
    # from the watchdog's view entirely instead of surfacing as needing attention.
    global LEDGER
    orig_ledger = LEDGER
    tmpdir = tempfile.mkdtemp(prefix="progress-ledger-selfcheck-corrupt-only-")
    LEDGER = pathlib.Path(tmpdir) / "progress.jsonl"
    try:
        with LEDGER.open("a") as f:
            f.write(json.dumps({"ev": "progress", "task_id": "badts", "owner": "o", "phase": "claimed",
                                 "ts": "bogus"}) + "\n")
        code, out, exc = _run(["stale", "--threshold-seconds", "1"])
        assert exc == 1, "a ledger with only a malformed-ts row must not exit 0 on a whole-ledger scan"
        assert '"task_id": "badts"' in out and '"status": "no_progress_recorded"' in out, (
            "the corrupted-only task-id must be reported no_progress_recorded, not silently dropped")
    finally:
        LEDGER = orig_ledger
        shutil.rmtree(tmpdir, ignore_errors=True)


def _selfcheck_recursionerror_in_all_task_ids():
    """CONFIRMED BUG (checker, round 9): _all_task_ids() has its OWN separate json.loads loop over the
    SAME ledger file as _recs() -- round 8 fixed _recs()'s RecursionError handling but missed this second
    loop, which still only caught ValueError. A deeply-nested-but-syntactically-valid JSONL line (e.g.
    ~1100 levels of nested arrays) still crashed a whole-ledger `stale`/`ready` scan (no --task-id, which
    is the only code path that calls _all_task_ids()) with an uncaught RecursionError. Isolated in its own
    fresh ledger/tmpdir (same precedent as _selfcheck_stale_scan_sees_corrupted_only_task above) so it
    never interacts with any other test's ledger state."""
    global LEDGER
    orig_ledger = LEDGER
    tmpdir = tempfile.mkdtemp(prefix="progress-ledger-selfcheck-deepnest-")
    LEDGER = pathlib.Path(tmpdir) / "progress.jsonl"
    try:
        code, _, _ = _run(["record", "--task-id", "normal-task", "--owner", "sm-normal",
                            "--phase", TERMINAL_PHASE])
        assert code == 0, "setup: a normal record must succeed"
        with LEDGER.open("a") as f:
            f.write("[" * 1100 + "]" * 1100 + "\n")

        code, out, exc = _run(["stale", "--threshold-seconds", "3600"])
        assert exc in (0, 1), (
            f"a whole-ledger `stale` scan (no --task-id) must never crash with a RecursionError on a "
            f"deeply-nested JSONL line: {out!r}")
        assert '"task_id": "normal-task"' not in out, (
            "normal-task was just recorded and must not be reported stale against a huge threshold")

        code, out, exc = _run(["ready"])
        assert code == 0 and exc is None, (
            f"a whole-ledger `ready` scan (no --task-id) must never crash with a RecursionError on a "
            f"deeply-nested JSONL line: {out!r}")
        assert '"task_id": "normal-task"' in out, (
            "a whole-ledger ready scan must still find the one legitimate terminal-phase task-id")
    finally:
        LEDGER = orig_ledger
        shutil.rmtree(tmpdir, ignore_errors=True)


def _selfcheck_default_ledger_path():
    # Same cross-worktree-sharing regression as claim-ledger.py's own _selfcheck_default_ledger_path:
    # a dispatcher (in the primary checkout) and a sub-supervisor (in a linked worktree) must resolve to
    # the IDENTICAL default ledger file with SM_PROGRESS_LEDGER/SM_LOOP_STATE both unset.
    tmp = tempfile.mkdtemp(prefix="progress-ledger-pathcheck-")
    try:
        repo = os.path.join(tmp, "repo")
        subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
        subprocess.run(["git", "-C", repo, "config", "user.email", "a@a"], check=True)
        subprocess.run(["git", "-C", repo, "config", "user.name", "a"], check=True)
        with open(os.path.join(repo, "f"), "w") as f:
            f.write("x")
        subprocess.run(["git", "-C", repo, "add", "-A"], check=True)
        subprocess.run(["git", "-C", repo, "commit", "-q", "-m", "init"], check=True)
        wt = os.path.join(tmp, "wt")
        subprocess.run(["git", "-C", repo, "worktree", "add", "-q", "-b", "feat", wt, "main"], check=True)

        env = {k: v for k, v in os.environ.items() if k not in ("SM_PROGRESS_LEDGER", "SM_LOOP_STATE")}

        def _cli(cwd, argv):
            return subprocess.run([sys.executable, _SCRIPT_PATH] + argv, cwd=cwd, env=env,
                                   capture_output=True, text=True)

        p1 = _cli(repo, ["record", "--task-id", "shared-task", "--owner", "sm-shared", "--phase", "claimed"])
        assert p1.returncode == 0, f"record from the primary checkout should succeed: {p1.stderr}"
        p2 = _cli(wt, ["latest"])
        assert p2.returncode == 0 and "shared-task" in p2.stdout, (
            "a record made from the primary checkout must be visible via `latest` from a DIFFERENT "
            "worktree of the same repo -- if not, the two CWDs resolved to two different default ledgers")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    p = argparse.ArgumentParser(description="self-reported progress checkpoints for fan-out sub-supervisors")
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("record")
    r.add_argument("--task-id", required=True)
    r.add_argument("--owner", required=True)
    r.add_argument("--phase", required=True)
    r.add_argument("--checked-sha")
    r.add_argument("--checker-verdict-path")
    r.add_argument("--batch-id")
    r.add_argument("--cost", type=float)
    r.add_argument("--tokens", type=float)
    r.add_argument("--duration-seconds", type=float)
    r.add_argument("--still-achievable", choices=["yes", "no"])
    r.add_argument("--note")

    sub.add_parser("latest")
    sub.add_parser("status")
    sub.add_parser("selfcheck")

    st = sub.add_parser("stale")
    st.add_argument("--threshold-seconds", required=True, type=int)
    st.add_argument("--task-id", action="append", default=None,
                     help="repeatable; every task-id ever seen in the ledger if omitted")

    rd = sub.add_parser("ready")
    rd.add_argument("--task-id", action="append", default=None,
                     help="repeatable; every task-id ever seen in the ledger if omitted")
    rd.add_argument("--batch-id", default=None,
                     help="restrict to task-ids whose terminal row was recorded with this --batch-id; "
                          "omit to see every ready task-id regardless of batch-id (trigger-A usage)")

    args = p.parse_args(argv)

    if args.cmd == "record":
        if not _valid_task_id(args.task_id):
            sys.exit(f"invalid --task-id {args.task_id!r}: must match [A-Za-z0-9_-] and be 1-128 chars")
        if not args.owner:
            sys.exit("--owner must be non-empty")
        if not _valid_phase(args.phase):
            sys.exit(f"invalid --phase {args.phase!r}: must match [A-Za-z0-9_-] and be 1-64 chars")
        if args.batch_id is not None and not _valid_task_id(args.batch_id):
            sys.exit(f"invalid --batch-id {args.batch_id!r}: must match [A-Za-z0-9_-] and be 1-128 chars")
        if args.cost is not None and not _valid_budget_number(args.cost):
            sys.exit(f"invalid --cost {args.cost!r}: must be a finite number >= 0")
        if args.tokens is not None and not _valid_budget_number(args.tokens):
            sys.exit(f"invalid --tokens {args.tokens!r}: must be a finite number >= 0")
        if args.duration_seconds is not None and not _valid_budget_number(args.duration_seconds):
            sys.exit(f"invalid --duration-seconds {args.duration_seconds!r}: must be a finite number >= 0")
        if args.note is not None and args.still_achievable is None:
            sys.exit("--note is only valid alongside --still-achievable")
        if args.note is not None and len(args.note) > NOTE_MAX_LEN:
            sys.exit(f"--note is too long ({len(args.note)} chars; max {NOTE_MAX_LEN})")
        rec = {"ev": "progress", "task_id": args.task_id, "owner": args.owner, "phase": args.phase,
               "ts": time.strftime("%Y-%m-%dT%H:%M:%S")}
        if args.checked_sha:
            rec["checked_sha"] = args.checked_sha
        if args.checker_verdict_path:
            rec["checker_verdict_path"] = args.checker_verdict_path
        if args.batch_id:
            rec["batch_id"] = args.batch_id
        if args.cost is not None:
            rec["cost"] = args.cost
        if args.tokens is not None:
            rec["tokens"] = args.tokens
        if args.duration_seconds is not None:
            rec["duration_seconds"] = args.duration_seconds
        if args.still_achievable is not None:
            rec["still_achievable"] = args.still_achievable
        if args.note is not None:
            rec["note"] = args.note
        with _ledger_lock():
            # Immutability: fold FRESH, inside the lock (same TOCTOU-safe precedent as
            # claim-ledger.py's own steal), right before deciding -- a task-id's batch membership is
            # fixed once, at the earliest checkpoint that declares one, and can never be changed by a
            # later record call for that SAME task-id. This is enforced at WRITE time (rejecting the
            # conflicting registration outright) rather than only filtered at `ready` read time, so an
            # inconsistent row is never written in the first place under normal operation.
            if args.batch_id:
                existing_binding, _ = _binding_batch_id(args.task_id, _recs())
                if existing_binding is not None and existing_binding != args.batch_id:
                    sys.exit(f"task-id {args.task_id} is already bound to batch-id {existing_binding!r} "
                              f"(established at its earliest checkpoint) -- refusing to rebind it to "
                              f"{args.batch_id!r}; a task-id's batch membership is immutable once set")
            _append(rec)
        print(f"recorded {args.task_id} phase={args.phase}")

    elif args.cmd in ("latest", "status"):
        latest = latest_by_task()
        if not latest and _BAD == 0:
            print("(no progress recorded)", file=sys.stderr)
        for task_id, r in sorted(latest.items()):
            line = f"[{task_id}] phase={r['phase']} owner={r['owner']} ts={r.get('ts', '?')}"
            if r.get("checked_sha"):
                line += f" checked_sha={r['checked_sha']}"
            if r.get("checker_verdict_path"):
                line += f" checker_verdict_path={r['checker_verdict_path']}"
            if r.get("batch_id"):
                line += f" batch_id={r['batch_id']}"
            if r.get("cost") is not None:
                line += f" cost={r['cost']}"
            if r.get("tokens") is not None:
                line += f" tokens={r['tokens']}"
            if r.get("duration_seconds") is not None:
                line += f" duration_seconds={r['duration_seconds']}"
            if r.get("still_achievable") is not None:
                line += f" still_achievable={r['still_achievable']}"
            if r.get("note") is not None:
                line += f" note={r['note']!r}"
            print(line)
        if _BAD:
            print(f"WARNING: {_BAD} malformed line(s) in {LEDGER} -- ledger may be corrupt; reconcile manually.")

    elif args.cmd == "stale":
        # read-only, no lock -- same lock-free precedent as claim-ledger.py's own `conflicts`.
        latest = latest_by_task()
        task_ids = args.task_id if args.task_id is not None else sorted(_all_task_ids())
        now = time.time()
        hits = []
        for task_id in task_ids:
            r = latest.get(task_id)
            if r is None:
                hits.append({"task_id": task_id, "status": "no_progress_recorded"})
                continue
            epoch = _ts_to_epoch(r["ts"])
            if epoch is None:
                continue  # unconvertible timestamp -- never prove staleness from it, conservative by design
            age = now - epoch
            if age > args.threshold_seconds:
                hits.append({"task_id": task_id, "status": "stale", "phase": r["phase"],
                             "last_ts": r["ts"], "age_seconds": int(age)})
        for h in hits:
            print(json.dumps(h))
        sys.exit(1 if hits else 0)

    elif args.cmd == "ready":
        # read-only, no lock -- same lock-free precedent as `stale`/claim-ledger.py's `conflicts`. Always
        # exits 0: unlike `stale`, a "ready" hit is the WANTED outcome, not a problem to report via exit
        # code -- callers get the actual list via stdout.
        recs = _recs()
        latest = latest_by_task(recs)
        task_ids = args.task_id if args.task_id is not None else sorted(_all_task_ids())
        for task_id in task_ids:
            r = latest.get(task_id)
            if r is None or r["phase"] != TERMINAL_PHASE:
                continue
            # --batch-id restricts to task-ids BOUND to this exact batch-id -- matched against the
            # task-id's own immutable, earliest-established binding (_binding_batch_id), never just its
            # terminal row. A task-id whose own row history is internally INCONSISTENT is excluded
            # outright, regardless of whether its terminal row happens to nominally match the query --
            # `record`'s own write-time guard should make this case rare under normal operation, but
            # `ready` never trusts a row that guard didn't see (e.g. a hand-edited/legacy ledger line).
            # Omitted --batch-id entirely means "no filtering", preserving trigger-A's existing
            # no-filter usage exactly.
            if args.batch_id is not None:
                binding, consistent = _binding_batch_id(task_id, recs)
                if not consistent or binding != args.batch_id:
                    continue
            hit = {"task_id": task_id, "ts": r["ts"]}
            if r.get("checked_sha"):
                hit["checked_sha"] = r["checked_sha"]
            if r.get("checker_verdict_path"):
                hit["checker_verdict_path"] = r["checker_verdict_path"]
            print(json.dumps(hit))

    elif args.cmd == "selfcheck":
        recs = [{"ev": "progress", "task_id": "a", "owner": "o", "phase": "claimed", "ts": "1"},
                 {"ev": "progress", "task_id": "a", "owner": "o", "phase": "maker_started", "ts": "2"},
                 {"ev": "progress", "task_id": "b", "owner": "o", "phase": "claimed", "ts": "3"}]
        folded = latest_by_task(recs)
        assert folded["a"]["phase"] == "maker_started", "latest-fold must keep the LAST record per task-id"
        assert folded["b"]["phase"] == "claimed", "latest-fold broken for a single-record task-id"
        assert latest_by_task([]) == {}, "empty ledger must fold to no known task-ids"
        assert _valid_task_id("sm-abc_123") and not _valid_task_id("../x") and not _valid_task_id("") \
            and not _valid_task_id("a/b") and not _valid_task_id("a" * 129), "task-id validation broken"
        assert _valid_phase(TERMINAL_PHASE) and not _valid_phase("") and not _valid_phase("bad phase"), (
            "phase validation broken")
        # CONFIRMED BUG (checker, same pattern already fixed in bin/pane-reaper.py's
        # _valid_positive_number): a native int this large previously crashed _valid_budget_number with
        # an uncaught OverflowError inside math.isfinite(x) (int-to-float conversion overflow), instead
        # of being accepted (it IS finite and >= 0 as a native Python int, which has no "infinite"
        # representation at all). Today's CLI only ever passes this function a float (argparse's own
        # type=float on --cost/--tokens/--duration-seconds), so this is exercised via a direct call,
        # mirroring pane-reaper.py's own 1000-digit-integer regression for the identical root cause.
        assert _valid_budget_number(10 ** 10000), "a huge native int must be a VALID budget number (finite, >= 0)"
        assert not _valid_budget_number(-(10 ** 10000)), "a huge NEGATIVE native int must still be rejected"
        _selfcheck_live()
        _selfcheck_stale_scan_sees_corrupted_only_task()
        _selfcheck_recursionerror_in_all_task_ids()
        _selfcheck_default_ledger_path()
        print("ok")


if __name__ == "__main__":
    main(sys.argv[1:])
