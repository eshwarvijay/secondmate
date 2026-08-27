#!/usr/bin/env python3
# ponytail: append-only JSONL ledger. Move to sqlite only if you ever get concurrent supervisor writers.
"""hold.py -- durable human-gate decisions for the maker/checker loop.

  hold.py hold --task T --q "question" [--opts "a|b|c"]  -> prints new id, records an OPEN decision
  hold.py answer ID --a "the decision"                   -> closes it
  hold.py open                                           -> lists unanswered (RUN AT SUPERVISOR START)
  hold.py selfcheck                                      -> asserts the open-fold is correct

Ledger path: $SM_HOLD_LEDGER, else ./decisions.jsonl in the CWD (one ledger per orchestration repo).
Nothing falls through a restart: `hold.py open` reconciles from disk, never from chat memory.
"""
import json, sys, os, time, argparse, pathlib, hashlib

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
    for line in LEDGER.read_text().splitlines():
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except ValueError:
            _BAD += 1; continue
        if isinstance(o, dict) and "ev" in o and "id" in o:
            recs.append(o)
        else:
            _BAD += 1
    return recs


def _append(rec):
    with LEDGER.open("a") as f:
        f.write(json.dumps(rec) + "\n")


def open_decisions(recs=None):
    recs = _recs() if recs is None else recs
    answered = {r["id"] for r in recs if r["ev"] == "answer"}
    return [r for r in recs if r["ev"] == "hold" and r["id"] not in answered]


def _mkid(task, q, ts):
    # finding #11: a random nonce so two identical holds in the same second get distinct ids.
    return hashlib.sha1(f"{task}{q}{ts}{os.urandom(4).hex()}".encode()).hexdigest()[:8]


def main(argv):
    p = argparse.ArgumentParser(description="durable human-gate decisions")
    sub = p.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("hold"); h.add_argument("--task", required=True); h.add_argument("--q", required=True); h.add_argument("--opts", default="")
    a = sub.add_parser("answer"); a.add_argument("id"); a.add_argument("--a", required=True)
    sub.add_parser("open"); sub.add_parser("selfcheck")
    args = p.parse_args(argv)

    if args.cmd == "hold":
        ts = time.strftime("%Y-%m-%dT%H:%M:%S")
        did = _mkid(args.task, args.q, ts)
        _append({"ev": "hold", "id": did, "ts": ts, "task": args.task, "q": args.q,
                 "opts": [o for o in args.opts.split("|") if o]})
        print(did)
    elif args.cmd == "answer":
        recs = _recs()
        holds = {r["id"] for r in recs if r["ev"] == "hold"}
        answered = {r["id"] for r in recs if r["ev"] == "answer"}
        if args.id not in holds:
            sys.exit(f"no decision with id {args.id}")
        if args.id in answered:  # finding #12: don't append a contradictory answer to a closed decision
            sys.exit(f"decision {args.id} is already answered")
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
    elif args.cmd == "selfcheck":
        recs = [{"ev": "hold", "id": "a", "task": "t", "q": "q1", "opts": []},
                {"ev": "hold", "id": "b", "task": "t", "q": "q2", "opts": []},
                {"ev": "answer", "id": "a", "a": "yes"}]
        assert [r["id"] for r in open_decisions(recs)] == ["b"], "open-fold broken"
        print("ok")


if __name__ == "__main__":
    main(sys.argv[1:])
