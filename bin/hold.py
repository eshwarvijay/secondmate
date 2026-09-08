#!/usr/bin/env python3
# ponytail: append-only JSONL ledger. Move to sqlite only if you ever get concurrent supervisor writers.
"""hold.py -- durable human-gate decisions for the maker/checker loop.

  hold.py hold --task T --q "question" [--opts "a|b|c"] [--sha SHA] -> prints new id, records an OPEN decision
  hold.py answer ID --a "the decision" [--sha SHA]                  -> closes it
  hold.py open                                                      -> lists unanswered (RUN AT SUPERVISOR START)
  hold.py next                                                      -> prints only the single oldest open decision
  hold.py selfcheck                                                 -> asserts the open-fold and SHA-binding are correct

Ledger path: $SM_HOLD_LEDGER, else ./decisions.jsonl in the CWD (one ledger per orchestration repo).
Nothing falls through a restart: `hold.py open` reconciles from disk, never from chat memory.

--sha binds a hold (and its id) to a specific commit SHA, so a later `answer` can be checked against
the exact code state the human was shown, not silently reattached to whatever state exists when
`answer` is called. Omitting --sha on `hold` keeps old behavior exactly (no --sha required on answer).
"""
import json, sys, os, time, argparse, pathlib, hashlib, contextlib, io, tempfile, shutil
try:
    import fcntl
except ImportError:  # non-Unix (e.g. Windows) -> best-effort, no locking
    fcntl = None

LEDGER = pathlib.Path(os.environ.get("SM_HOLD_LEDGER", "decisions.jsonl"))
_BAD = 0  # count of malformed/incomplete ledger lines seen by the last _recs()


def _recs():
    # finding #6: parse tolerantly — skip malformed/incomplete lines but COUNT them, so `open` warns
    # (fail-closed) instead of a partial write silently hiding a pending decision.
    global _BAD
    _BAD = 0
    recs = []
    if not LEDGER.exists():
        return recs
    for line in LEDGER.read_text(errors="replace").splitlines():   # finding #5: tolerate invalid UTF-8
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except ValueError:
            _BAD += 1; continue
        if isinstance(o, dict) and o.get("ev") in ("hold", "answer") and isinstance(o.get("id"), str):  # #5: id must be a hashable string
            if o["ev"] == "answer" and "a" not in o:   # finding #1: an incomplete answer must not close a hold
                _BAD += 1; continue
            recs.append(o)
        else:
            _BAD += 1
    return recs


def _append(rec):
    with LEDGER.open("a") as f:
        f.write(json.dumps(rec) + "\n")


@contextlib.contextmanager
def _ledger_lock():
    # C-fix: serialize concurrent mutations (esp. answer's read-check-append) with an exclusive OS lock.
    if fcntl is None:
        yield; return
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    with open(str(LEDGER) + ".lock", "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def open_decisions(recs=None):
    recs = _recs() if recs is None else recs
    answered = {r["id"] for r in recs if r["ev"] == "answer"}
    return [r for r in recs if r["ev"] == "hold" and r["id"] not in answered]


def _mkid(task, q, ts, sha=""):
    # finding #11: a random nonce so two identical holds in the same second get distinct ids.
    # sha (if given) is folded into the hash too, so the id itself is bound to that state, not just
    # carried as separate metadata that could be silently ignored.
    return hashlib.sha1(f"{task}{q}{ts}{sha}{os.urandom(4).hex()}".encode()).hexdigest()[:8]


def _oldest_open(recs=None):
    # single-item retrieval primitive for `next`: oldest by ts, ties broken by ledger insertion order.
    rows = open_decisions(recs)
    if not rows:
        return None
    return min(enumerate(rows), key=lambda ir: (ir[1].get("ts", ""), ir[0]))[1]


def _run(argv):
    # selfcheck helper: invoke the REAL main() (real argparse, real hold/answer/next code paths, real
    # _ledger_lock/_recs/_append) against whatever LEDGER is currently pointed at, and capture the
    # result instead of reimplementing any of hold.py's own matching/serialization logic.
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
    # Runs the *actual* CLI paths (main -> hold/answer/next) against a scratch ledger in a temp dir,
    # so this selfcheck would fail if the real --sha binding / next-primitive were ever broken --
    # not a parallel reimplementation of that logic.
    global LEDGER
    orig_ledger = LEDGER
    tmpdir = tempfile.mkdtemp(prefix="hold-selfcheck-")
    LEDGER = pathlib.Path(tmpdir) / "decisions.jsonl"
    try:
        # a hold created with --sha X can be validly answered with --sha X.
        code, did, _ = _run(["hold", "--task", "t", "--q", "ready to merge?", "--sha", "deadbeef"])
        assert code == 0, "hold with --sha should succeed"
        code, _, _ = _run(["answer", did, "--a", "merge", "--sha", "deadbeef"])
        assert code == 0, "answer with matching --sha should succeed"
        assert did in {r["id"] for r in _recs() if r["ev"] == "answer"}, "matching-sha answer did not close the hold"

        # the same hold cannot be answered with a DIFFERENT --sha: must fail, must not append a record.
        code, did2, _ = _run(["hold", "--task", "t", "--q", "ready to merge (again)?", "--sha", "aaaa111"])
        assert code == 0
        pre_len = len(_recs())
        code, _, exc = _run(["answer", did2, "--a", "merge", "--sha", "bbbb222"])
        assert code != 0, "mismatched --sha on answer must fail"
        assert "sha" in str(exc).lower(), "mismatched-sha rejection should explain why in the error"
        assert len(_recs()) == pre_len, "rejected answer must not append any (corrupting) record"
        assert did2 in {r["id"] for r in open_decisions()}, "hold must stay open after a rejected answer"

        # backward compat: a hold created WITHOUT --sha can still be answered with no --sha required.
        code, did3, _ = _run(["hold", "--task", "t", "--q", "no sha here"])
        assert code == 0
        code, _, _ = _run(["answer", did3, "--a", "ok"])
        assert code == 0, "answering a no-sha hold with no --sha must still work (backward compat)"

        # `next` returns exactly the single oldest still-open hold when several are open, and reports
        # "(no open decisions)" once none remain.
        LEDGER.write_text("")  # clean ledger for a controlled `next` scenario
        _append({"ev": "hold", "id": "n1", "ts": "2024-01-01T00:00:00", "task": "t", "q": "first", "opts": []})
        _append({"ev": "hold", "id": "n2", "ts": "2024-01-02T00:00:00", "task": "t", "q": "second", "opts": []})
        code, out, _ = _run(["next"])
        assert code == 0 and out.startswith("[n1]"), "next must return the single oldest open hold"
        code, _, _ = _run(["answer", "n1", "--a", "done"])
        assert code == 0
        code, out, _ = _run(["next"])
        assert code == 0 and out.startswith("[n2]"), "next must advance once the oldest hold is answered"
        code, _, _ = _run(["answer", "n2", "--a", "done"])
        assert code == 0
        code, out, _ = _run(["next"])
        assert code != 0, "next with no open holds must exit nonzero (no open decisions)"
    finally:
        LEDGER = orig_ledger
        shutil.rmtree(tmpdir, ignore_errors=True)


def main(argv):
    p = argparse.ArgumentParser(description="durable human-gate decisions")
    sub = p.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("hold"); h.add_argument("--task", required=True); h.add_argument("--q", required=True); h.add_argument("--opts", default=""); h.add_argument("--sha", default="")
    a = sub.add_parser("answer"); a.add_argument("id"); a.add_argument("--a", required=True); a.add_argument("--sha", default="")
    sub.add_parser("open"); sub.add_parser("next"); sub.add_parser("selfcheck")
    args = p.parse_args(argv)

    if args.cmd == "hold":
        with _ledger_lock():
            ts = time.strftime("%Y-%m-%dT%H:%M:%S")
            did = _mkid(args.task, args.q, ts, args.sha)
            rec = {"ev": "hold", "id": did, "ts": ts, "task": args.task, "q": args.q,
                   "opts": [o for o in args.opts.split("|") if o]}
            if args.sha:   # only add the key when given, so old ledgers with no "sha" key stay the same shape
                rec["sha"] = args.sha
            _append(rec)
        print(did)
    elif args.cmd == "answer":
        with _ledger_lock():   # C-fix: read-check-append is atomic vs concurrent answers
            recs = _recs()
            hold_by_id = {r["id"]: r for r in recs if r["ev"] == "hold"}
            answered = {r["id"] for r in recs if r["ev"] == "answer"}
            if args.id not in hold_by_id:
                sys.exit(f"no decision with id {args.id}")
            if args.id in answered:  # finding #12: don't append a contradictory answer to a closed decision
                sys.exit(f"decision {args.id} is already answered")
            # finding: a hold created with --sha binds the id to that state; answer must match it exactly,
            # so a human's decision can't be silently reattached to a later, different code state.
            hold_sha = hold_by_id[args.id].get("sha")
            if hold_sha and args.sha != hold_sha:
                sys.exit(f"decision {args.id} was held at sha {hold_sha}, but answer supplied sha "
                         f"{args.sha or '(none)'} -- refusing to attach an answer to a different code state")
            _append({"ev": "answer", "id": args.id, "ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "a": args.a})
    elif args.cmd == "open":
        rows = open_decisions()
        if not rows and _BAD == 0:
            print("(no open decisions)", file=sys.stderr)  # stderr: keeps SessionStart-hook stdout clean when empty
        for r in rows:
            opts = r.get("opts") or []
            print(f"[{r['id']}] ({r.get('task', '?')}) {r.get('q', '?')}" + (f"   opts: {', '.join(opts)}" if opts else ""))
        if _BAD:  # surface corruption on stdout so the SessionStart hook shows it — never fail open
            print(f"WARNING: {_BAD} malformed line(s) in {LEDGER} — ledger may be corrupt; reconcile manually.")
    elif args.cmd == "next":
        # single-item serialization primitive: whatever calls this gets exactly one open decision to
        # act on, oldest first, by construction -- not by caller discipline over the full `open` list.
        row = _oldest_open()
        if row is None:
            print("(no open decisions)", file=sys.stderr)  # same convention as `open`'s empty case
            sys.exit(1)
        opts = row.get("opts") or []
        print(f"[{row['id']}] ({row.get('task', '?')}) {row.get('q', '?')}" + (f"   opts: {', '.join(opts)}" if opts else ""))
    elif args.cmd == "selfcheck":
        recs = [{"ev": "hold", "id": "a", "task": "t", "q": "q1", "opts": []},
                {"ev": "hold", "id": "b", "task": "t", "q": "q2", "opts": []},
                {"ev": "answer", "id": "a", "a": "yes"}]
        assert [r["id"] for r in open_decisions(recs)] == ["b"], "open-fold broken"
        assert _oldest_open(recs)["id"] == "b", "next-primitive broken (should return the single oldest open hold)"
        assert _oldest_open([]) is None, "next-primitive should report no open holds when there are none"
        _selfcheck_live()
        print("ok")


if __name__ == "__main__":
    main(sys.argv[1:])
