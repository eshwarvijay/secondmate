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
    [--checked-sha SHA] [--checker-verdict-path PATH]                    --checked-sha/--checker-verdict-path
                                                                           are free-form optional extras, meant
                                                                           for the terminal `verify_gate_pass`
                                                                           phase (see vocabulary below) so a
                                                                           later batch-close consumer can read
                                                                           them off that one row -- this script
                                                                           does not enforce which phase they're
                                                                           attached to.
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
                                                                           out, never continuously.
  progress-ledger.py selfcheck                                        -> asserts the fold + drives the real
                                                                           CLI paths against a scratch ledger.

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
import json, sys, os, time, re, subprocess, argparse, pathlib, contextlib, io, tempfile, shutil
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
        except ValueError:
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
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("ev") == "progress" and isinstance(o.get("task_id"), str):
            ids.add(o["task_id"])
    return ids


def _ts_to_epoch(ts):
    # ts is always written by this script's own time.strftime("%Y-%m-%dT%H:%M:%S") (local time, matching
    # claim-ledger.py/hold.py) -- parse it back with the same local-time interpretation via mktime.
    return time.mktime(time.strptime(ts, "%Y-%m-%dT%H:%M:%S"))


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

        # stale with no --task-id at all considers every task-id ever seen in the ledger -- INCLUDING one
        # whose only row failed the ts-shape fold above ("badts"), which must still surface as
        # no_progress_recorded rather than silently vanish from a whole-ledger scan just because its one
        # row never made it into latest_by_task.
        code, out, exc = _run(["stale", "--threshold-seconds", "60"])
        assert exc == 1 and '"task_id": "old"' in out and '"task_id": "t1"' not in out, (
            "omitting --task-id must scan every known task-id, reporting only the actually-stale ones")
        assert '"task_id": "badts", "status": "no_progress_recorded"' in out, (
            "a whole-ledger scan must still report a task-id whose only row failed ts validation")

        # `stale` never appends -- it's read-only, like claim-ledger.py's own `conflicts`.
        pre_len = len(_recs())
        _run(["stale", "--threshold-seconds", "1", "--task-id", "t1"])
        assert len(_recs()) == pre_len, "stale must never append to the ledger"

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

    sub.add_parser("latest")
    sub.add_parser("status")
    sub.add_parser("selfcheck")

    st = sub.add_parser("stale")
    st.add_argument("--threshold-seconds", required=True, type=int)
    st.add_argument("--task-id", action="append", default=None,
                     help="repeatable; every task-id ever seen in the ledger if omitted")

    args = p.parse_args(argv)

    if args.cmd == "record":
        if not _valid_task_id(args.task_id):
            sys.exit(f"invalid --task-id {args.task_id!r}: must match [A-Za-z0-9_-] and be 1-128 chars")
        if not args.owner:
            sys.exit("--owner must be non-empty")
        if not _valid_phase(args.phase):
            sys.exit(f"invalid --phase {args.phase!r}: must match [A-Za-z0-9_-] and be 1-64 chars")
        rec = {"ev": "progress", "task_id": args.task_id, "owner": args.owner, "phase": args.phase,
               "ts": time.strftime("%Y-%m-%dT%H:%M:%S")}
        if args.checked_sha:
            rec["checked_sha"] = args.checked_sha
        if args.checker_verdict_path:
            rec["checker_verdict_path"] = args.checker_verdict_path
        with _ledger_lock():
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
            age = now - _ts_to_epoch(r["ts"])
            if age > args.threshold_seconds:
                hits.append({"task_id": task_id, "status": "stale", "phase": r["phase"],
                             "last_ts": r["ts"], "age_seconds": int(age)})
        for h in hits:
            print(json.dumps(h))
        sys.exit(1 if hits else 0)

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
        _selfcheck_live()
        _selfcheck_stale_scan_sees_corrupted_only_task()
        _selfcheck_default_ledger_path()
        print("ok")


if __name__ == "__main__":
    main(sys.argv[1:])
