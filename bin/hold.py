#!/usr/bin/env python3
# ponytail: append-only JSONL ledger. Move to sqlite only if you ever get concurrent supervisor writers.
"""hold.py -- durable human-gate decisions for the maker/checker loop (steal #1, from firstmate fm-captain-hold.sh).

  hold.py hold --task T --q "question" [--opts "a|b|c"]  -> prints new id, records an OPEN decision
  hold.py answer ID --a "the decision"                   -> closes it
  hold.py open                                           -> lists unanswered (RUN AT SUPERVISOR START)
  hold.py selfcheck                                      -> asserts the open-fold is correct

Ledger path: $FM_HOLD_LEDGER, else ./decisions.jsonl in the CWD (per-orchestration-repo, like firstmate's per-home state).
Nothing falls through a restart: `hold.py open` reconciles from disk, never from chat memory.
"""
import json, sys, os, time, argparse, pathlib, hashlib

LEDGER = pathlib.Path(os.environ.get("FM_HOLD_LEDGER", "decisions.jsonl"))


def _recs():
    if not LEDGER.exists():
        return []
    return [json.loads(l) for l in LEDGER.read_text().splitlines() if l.strip()]


def _append(rec):
    with LEDGER.open("a") as f:
        f.write(json.dumps(rec) + "\n")


def open_decisions(recs=None):
    recs = _recs() if recs is None else recs
    answered = {r["id"] for r in recs if r["ev"] == "answer"}
    return [r for r in recs if r["ev"] == "hold" and r["id"] not in answered]


def _mkid(task, q, ts):
    return hashlib.sha1(f"{task}{q}{ts}".encode()).hexdigest()[:8]


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
        if not any(r["ev"] == "hold" and r["id"] == args.id for r in _recs()):
            sys.exit(f"no open decision with id {args.id}")
        _append({"ev": "answer", "id": args.id, "ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "a": args.a})
    elif args.cmd == "open":
        rows = open_decisions()
        if not rows:
            print("(no open decisions)", file=sys.stderr)  # stderr: keeps SessionStart-hook stdout clean when empty
        for r in rows:
            print(f"[{r['id']}] ({r['task']}) {r['q']}" + (f"   opts: {', '.join(r['opts'])}" if r["opts"] else ""))
    elif args.cmd == "selfcheck":
        recs = [{"ev": "hold", "id": "a", "task": "t", "q": "q1", "opts": []},
                {"ev": "hold", "id": "b", "task": "t", "q": "q2", "opts": []},
                {"ev": "answer", "id": "a", "a": "yes"}]
        assert [r["id"] for r in open_decisions(recs)] == ["b"], "open-fold broken"
        print("ok")


if __name__ == "__main__":
    main(sys.argv[1:])
