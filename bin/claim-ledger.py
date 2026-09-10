#!/usr/bin/env python3
# ponytail: append-only JSONL ledger, fcntl-locked -- same idiom as hold.py. No sqlite, no heartbeats,
# no compaction: this is a human-supervised batch tool, not a system processing thousands of tasks.
"""claim-ledger.py -- atomic task-id claims so concurrently-running sub-agent-supervisors (each in its own
git worktree) never work the same task at once.

  claim-ledger.py claim   --task-id ID --owner LABEL              -> claims ID iff no open claim exists
  claim-ledger.py release --task-id ID --owner LABEL              -> closes ID's open claim (owner must match)
  claim-ledger.py steal   --task-id ID --owner LABEL --reason TXT -> human-supervised override: unconditionally
                                                                      closes whatever is open on ID (if anything)
                                                                      and reopens it under LABEL
  claim-ledger.py status | list                                   -> lists all currently-open claims
  claim-ledger.py selfcheck                                       -> asserts the fold + drives the real CLI paths

Ledger path: $SM_CLAIM_LEDGER, else ${SM_LOOP_STATE:-.secondmate}/claims.jsonl.

Claim key is task-id -- this repo's convention is one task-id : one worktree : one branch (sm/<task-id>),
so task-id is the natural claim key. NOT a worktree path, NOT a PID.

No liveness/heartbeat/TTL/lease logic here, ever. This script is a collision-prevention bookkeeping layer,
not a liveness oracle -- it has no reliable way to check liveness for whichever runtime is calling it (a raw
OS PID means nothing for an Agent-tool background agent, for instance). Each real sub-agent runtime already
has its own liveness mechanism (`herdr agent get <name>`, Agent-tool completion events). The reclaim path is
`steal`, which is a mandatory-reason, human-supervised override -- the CALLER (a dispatch loop) is
responsible for checking real liveness via whatever mechanism fits its runtime BEFORE ever invoking --steal.
"""
import json, sys, os, time, re, argparse, pathlib, contextlib, io, tempfile, shutil
try:
    import fcntl
except ImportError:  # non-Unix (e.g. Windows) -> best-effort, no locking
    fcntl = None

LEDGER = pathlib.Path(os.environ.get(
    "SM_CLAIM_LEDGER",
    str(pathlib.Path(os.environ.get("SM_LOOP_STATE", ".secondmate")) / "claims.jsonl"),
))
_BAD = 0  # count of malformed/incomplete ledger lines seen by the last _recs()

# task-id must be a safe bare identifier: no path separators, no null bytes, no empty string, bounded
# length -- mirrors the defensive posture in plan-committee.sh's _claim_task_marker (path-traversal /
# symlink / self-name-matching bugs found and fixed there earlier this session).
_TASK_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


def _valid_task_id(task_id):
    return isinstance(task_id, str) and bool(_TASK_ID_RE.match(task_id))


def _recs():
    # tolerant parse: skip malformed/incomplete lines but COUNT them (same discipline as hold.py), so
    # `status` warns instead of a partial write silently hiding an open claim.
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
        if (isinstance(o, dict) and o.get("ev") in ("claimed", "released", "stolen")
                and isinstance(o.get("task_id"), str) and isinstance(o.get("owner"), str)):
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
    # Same fcntl idiom as hold.py's _ledger_lock(): serialize concurrent mutations (the read-check-append
    # in claim/release/steal) with an exclusive OS lock on a sibling .lock file.
    if fcntl is None:
        yield; return
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    with open(str(LEDGER) + ".lock", "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def open_claims(recs=None):
    """Fold the ledger to {task_id: currently-open claim record}. This is THE ONE fold primitive that
    both `status` and `steal` use -- steal re-folds fresh, inside the lock, immediately before deciding,
    never trusting an earlier separately-fetched status call (closes the TOCTOU class the committee flagged)."""
    recs = _recs() if recs is None else recs
    open_by_task = {}
    for r in recs:
        if r["ev"] in ("claimed", "stolen"):
            open_by_task[r["task_id"]] = r
        elif r["ev"] == "released":
            open_by_task.pop(r["task_id"], None)
    return open_by_task


def _run(argv):
    # selfcheck helper: invoke the REAL main() (real argparse, real claim/release/steal/status code
    # paths, real _ledger_lock/_recs/_append/open_claims) and capture the result, instead of
    # reimplementing any of this script's own logic.
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
    # Runs the *actual* CLI paths (main -> claim/release/steal/status) against a scratch ledger in a
    # temp dir, so this selfcheck would fail if the real ownership check / TOCTOU-safe steal fold /
    # task-id validation were ever broken -- not a parallel reimplementation of that logic.
    global LEDGER
    orig_ledger = LEDGER
    tmpdir = tempfile.mkdtemp(prefix="claim-ledger-selfcheck-")
    LEDGER = pathlib.Path(tmpdir) / "claims.jsonl"
    try:
        # basic claim -> visible in status -> release -> gone from status.
        code, _, _ = _run(["claim", "--task-id", "t1", "--owner", "agent-a"])
        assert code == 0, "first claim on an unclaimed task-id should succeed"
        code, out, _ = _run(["status"])
        assert code == 0 and "t1" in out and "agent-a" in out, "status must show the open claim"

        # collision: a different owner claiming an already-open task-id must fail, and append nothing.
        pre_len = len(_recs())
        code, _, exc = _run(["claim", "--task-id", "t1", "--owner", "agent-b"])
        assert code != 0, "claiming an already-open task-id must fail"
        assert len(_recs()) == pre_len, "a rejected claim must not append any record"

        # settled decision #3: claim is NOT idempotent, even for the SAME owner re-claiming.
        code, _, exc = _run(["claim", "--task-id", "t1", "--owner", "agent-a"])
        assert code != 0, "re-claiming an already-open task-id must fail even for the same owner"

        # ownership check on release: a different owner's release must be rejected (IDOR-style guard).
        pre_len = len(_recs())
        code, _, exc = _run(["release", "--task-id", "t1", "--owner", "agent-b"])
        assert code != 0, "release by a non-owning owner must be rejected"
        assert "agent-b" not in str(exc) or "agent-a" in str(exc), "rejection should name the real owner"
        assert len(_recs()) == pre_len, "a rejected release must not append any record"
        assert "t1" in open_claims(), "claim must stay open after a rejected release"

        # release by the true owner succeeds, and the task-id becomes claimable again.
        code, _, _ = _run(["release", "--task-id", "t1", "--owner", "agent-a"])
        assert code == 0, "release by the true owner must succeed"
        assert "t1" not in open_claims(), "released task-id must not show as open"
        code, _, _ = _run(["claim", "--task-id", "t1", "--owner", "agent-c"])
        assert code == 0, "a released task-id must be claimable again by anyone"

        # release with no open claim at all must fail cleanly.
        code, _, _ = _run(["release", "--task-id", "t1", "--owner", "agent-c"])
        assert code == 0
        code, _, _ = _run(["release", "--task-id", "t1", "--owner", "agent-c"])
        assert code != 0, "releasing a task-id with no open claim must fail"

        # steal requires a non-empty --reason.
        code, _, exc = _run(["steal", "--task-id", "t1", "--owner", "agent-d", "--reason", "   "])
        assert code != 0, "steal with a blank --reason must be rejected"

        # steal on a task-id with NO current open claim still works, and its event type is 'stolen'
        # (distinct from 'claimed'), for an honest audit trail.
        code, _, _ = _run(["steal", "--task-id", "t1", "--owner", "agent-d", "--reason", "human override, agent-c stalled"])
        assert code == 0
        stolen_recs = [r for r in _recs() if r["ev"] == "stolen" and r["task_id"] == "t1"]
        assert stolen_recs and stolen_recs[-1]["owner"] == "agent-d", "steal must record a distinct 'stolen' event"
        assert "reason" in stolen_recs[-1] and stolen_recs[-1]["reason"].strip(), "stolen record must carry the reason"

        # steal unconditionally closes whatever was open (even mid-claim by yet another owner) and
        # reopens under the new owner.
        code, _, _ = _run(["claim", "--task-id", "t2", "--owner", "agent-e"])
        assert code == 0
        code, _, _ = _run(["steal", "--task-id", "t2", "--owner", "agent-f", "--reason", "reclaim stalled task"])
        assert code == 0
        opened = open_claims()
        assert opened["t2"]["owner"] == "agent-f", "steal must reopen the task-id under the new owner"

        # TOCTOU guard, forced via a GENUINE concurrent race (not a pre-written ledger line the steal
        # call then just reads normally -- that proves nothing, since nothing else is running while it
        # reads). A background thread performs a full COMPETING steal on the same task-id, released the
        # instant our own fold call returns, so its window to run lands exactly in the gap between our
        # fold and our lock acquisition -- the real defect being guarded against. If steal ever folds
        # BEFORE acquiring the lock again, the competitor can complete during that gap and our own
        # recorded previous_owner will be stale; if steal folds INSIDE the lock (the fix), the
        # competitor blocks on the same fcntl lock and cannot run until we're done.
        import threading
        _append({"ev": "claimed", "task_id": "race", "owner": "agent-a", "ts": time.strftime("%Y-%m-%dT%H:%M:%S")})
        real_open_claims = open_claims
        race_started = threading.Event()

        def _slow_open_claims(recs=None):
            result = real_open_claims(recs)
            if "race" in result and not race_started.is_set():
                race_started.set()  # let the competitor go, then hold this result open for a window
                time.sleep(0.3)
            return result

        def _competitor():
            race_started.wait(timeout=2)
            with contextlib.redirect_stdout(io.StringIO()):
                main(["steal", "--task-id", "race", "--owner", "concurrent-winner", "--reason", "racing steal"])

        t = threading.Thread(target=_competitor)
        t.start()
        globals()["open_claims"] = _slow_open_claims
        try:
            code, _, _ = _run(["steal", "--task-id", "race", "--owner", "victim-thief", "--reason", "toctou race"])
        finally:
            globals()["open_claims"] = real_open_claims
        t.join(timeout=5)
        assert not t.is_alive(), "competitor steal thread never finished -- test setup broken"
        assert code == 0

        # Ledger append order under the fcntl lock IS the true chronological order (ts has only
        # 1-second resolution, so it can't be trusted to order these two). Every 'stolen' record's
        # previous_owner must match the owner of whichever record truly precedes it in ledger order.
        race_recs = [r for r in _recs() if r["task_id"] == "race" and r["ev"] in ("claimed", "stolen")]
        assert len(race_recs) == 3, "expected exactly claimed + 2 stolen records for 'race'"
        for i in range(1, len(race_recs)):
            if race_recs[i]["ev"] == "stolen" and "previous_owner" in race_recs[i]:
                assert race_recs[i]["previous_owner"] == race_recs[i - 1]["owner"], (
                    f"stolen record claims previous_owner={race_recs[i]['previous_owner']!r} but the ledger's "
                    f"true immediately-preceding owner was {race_recs[i - 1]['owner']!r} -- steal must fold "
                    f"the ledger fresh INSIDE the lock, not from a stale pre-lock snapshot")

        # task-id validation: empty, path separators, null bytes, bad chars, and over-length must all fail.
        for bad in ("", "../etc", "a/b", "a\0b", "bad id", "*", "a" * 129):
            code, _, _ = _run(["claim", "--task-id", bad, "--owner", "agent-x"])
            assert code != 0, f"invalid task-id {bad!r} must be rejected"

        # status must warn (not silently hide) when the ledger has malformed lines.
        with LEDGER.open("a") as f:
            f.write("not json at all\n")
        code, out, _ = _run(["status"])
        assert code == 0 and "malformed" in out.lower(), "status must surface malformed-line corruption"

        # real concurrency: N threads racing to claim the SAME task-id simultaneously must yield exactly
        # one winner, and the ledger must end up with exactly one 'claimed' record for it -- proves the
        # fcntl lock (and folding inside it) actually serializes the read-check-append, not just in theory.
        results = []
        barrier = threading.Barrier(8)

        def _attempt(i):
            barrier.wait()
            try:
                main(["claim", "--task-id", "conc", "--owner", f"agent-{i}"])
                results.append(True)
            except SystemExit:
                results.append(False)

        threads = [threading.Thread(target=_attempt, args=(i,)) for i in range(8)]
        with contextlib.redirect_stdout(io.StringIO()):
            for t in threads:
                t.start()
            for t in threads:
                t.join()
        assert results.count(True) == 1, "exactly one concurrent claim on the same task-id must win"
        claimed_for_conc = [r for r in _recs() if r["ev"] == "claimed" and r["task_id"] == "conc"]
        assert len(claimed_for_conc) == 1, "the lock must prevent more than one 'claimed' record for the same task-id"
    finally:
        LEDGER = orig_ledger
        shutil.rmtree(tmpdir, ignore_errors=True)


def main(argv):
    p = argparse.ArgumentParser(description="atomic task-id claims for concurrent sub-agent-supervisors")
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("claim")
    c.add_argument("--task-id", required=True)
    c.add_argument("--owner", required=True)

    r = sub.add_parser("release")
    r.add_argument("--task-id", required=True)
    r.add_argument("--owner", required=True)

    s = sub.add_parser("steal")
    s.add_argument("--task-id", required=True)
    s.add_argument("--owner", required=True)
    s.add_argument("--reason", required=True)

    sub.add_parser("status")
    sub.add_parser("list")
    sub.add_parser("selfcheck")
    args = p.parse_args(argv)

    if args.cmd in ("claim", "release", "steal"):
        if not _valid_task_id(args.task_id):
            sys.exit(f"invalid --task-id {args.task_id!r}: must match [A-Za-z0-9_-] and be 1-128 chars "
                      f"(no path separators, no null bytes, no empty string)")
        if not args.owner:
            sys.exit("--owner must be non-empty")

    if args.cmd == "claim":
        with _ledger_lock():   # read-check-append is atomic vs a concurrent claim/steal on the same task-id
            opened = open_claims()
            existing = opened.get(args.task_id)
            if existing is not None:
                sys.exit(f"task-id {args.task_id} is already claimed by {existing['owner']} "
                         f"(since {existing.get('ts', '?')}) -- release it first, or --steal with a reason")
            ts = time.strftime("%Y-%m-%dT%H:%M:%S")
            _append({"ev": "claimed", "task_id": args.task_id, "owner": args.owner, "ts": ts})
        print(f"claimed {args.task_id} for {args.owner}")

    elif args.cmd == "release":
        with _ledger_lock():
            opened = open_claims()
            existing = opened.get(args.task_id)
            if existing is None:
                sys.exit(f"no open claim for task-id {args.task_id} -- nothing to release")
            if existing["owner"] != args.owner:
                sys.exit(f"task-id {args.task_id} is claimed by {existing['owner']}, not {args.owner} "
                         f"-- refusing release (use --steal with a reason if this is a deliberate override)")
            ts = time.strftime("%Y-%m-%dT%H:%M:%S")
            _append({"ev": "released", "task_id": args.task_id, "owner": args.owner, "ts": ts})
        print(f"released {args.task_id}")

    elif args.cmd == "steal":
        if not args.reason.strip():
            sys.exit("--reason must be non-empty -- steal is a human-supervised override and the ledger "
                      "must record why the claim was reclaimed")
        with _ledger_lock():
            # Fold FRESH, inside the lock, right before deciding -- never trust an earlier snapshot.
            opened = open_claims()
            prev = opened.get(args.task_id)
            ts = time.strftime("%Y-%m-%dT%H:%M:%S")
            rec = {"ev": "stolen", "task_id": args.task_id, "owner": args.owner, "ts": ts,
                   "reason": args.reason}
            if prev is not None:
                rec["previous_owner"] = prev["owner"]
            _append(rec)
        if prev is not None:
            print(f"stole {args.task_id} from {prev['owner']} for {args.owner}: {args.reason}")
        else:
            print(f"claimed (via steal, no prior open claim) {args.task_id} for {args.owner}: {args.reason}")

    elif args.cmd in ("status", "list"):
        opened = open_claims()
        if not opened and _BAD == 0:
            print("(no open claims)", file=sys.stderr)  # stderr keeps stdout clean when empty
        for task_id, r in sorted(opened.items()):
            print(f"[{task_id}] owner={r['owner']} claimed_at={r.get('ts', '?')}")
        if _BAD:  # surface corruption on stdout -- never fail open
            print(f"WARNING: {_BAD} malformed line(s) in {LEDGER} -- ledger may be corrupt; reconcile manually.")

    elif args.cmd == "selfcheck":
        recs = [{"ev": "claimed", "task_id": "t", "owner": "a", "ts": "1"},
                 {"ev": "claimed", "task_id": "u", "owner": "b", "ts": "2"},
                 {"ev": "released", "task_id": "t", "owner": "a", "ts": "3"}]
        assert set(open_claims(recs).keys()) == {"u"}, "open-fold broken"
        recs2 = recs + [{"ev": "stolen", "task_id": "u", "owner": "c", "ts": "4", "reason": "x"}]
        assert open_claims(recs2)["u"]["owner"] == "c", "stolen event must reopen the claim under the new owner"
        assert open_claims([]) == {}, "empty ledger must fold to no open claims"
        assert _valid_task_id("sm-abc_123") and not _valid_task_id("../x") and not _valid_task_id("") \
            and not _valid_task_id("a/b") and not _valid_task_id("a" * 129), "task-id validation broken"
        _selfcheck_live()
        print("ok")


if __name__ == "__main__":
    main(sys.argv[1:])
