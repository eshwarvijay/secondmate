#!/usr/bin/env python3
# ponytail: append-only JSONL ledger. Move to sqlite only if you ever get concurrent supervisor writers.
"""hold.py -- durable human-gate decisions for the maker/checker loop.

  hold.py hold --task T --q "question" [--opts "a|b|c"] [--sha SHA] -> prints new id, records an OPEN decision
  hold.py hold --task T --q "question" --entries-file PATH          -> a CONSOLIDATED BATCH hold: one genuine
                                                                        human decision covering several task-ids
                                                                        at once (see "Batch holds" below), instead
                                                                        of a separate --sha hold per task-id.
                                                                        Mutually exclusive with --sha (a batch
                                                                        hold's per-task-id checked-shas live in
                                                                        its own entries instead).
  hold.py answer ID --a "the decision" [--sha SHA]                  -> closes a single-task hold
  hold.py answer ID --approve "id1,id2" --reject "id3,id4"          -> closes a BATCH hold: every task-id in the
                                                                        hold's own entries must appear in exactly
                                                                        one of --approve/--reject (structured, not
                                                                        freeform prose a caller would have to
                                                                        regex out of a decision string)
  hold.py open                                                      -> lists unanswered (RUN AT SUPERVISOR START)
  hold.py next                                                      -> prints only the single oldest open decision
  hold.py selfcheck                                                 -> asserts the open-fold and SHA-binding are correct

Ledger path: $SM_HOLD_LEDGER, else ./decisions.jsonl in the CWD (one ledger per orchestration repo).
Nothing falls through a restart: `hold.py open` reconciles from disk, never from chat memory.

--sha binds a hold (and its id) to a specific commit SHA, so a later `answer` can be checked against
the exact code state the human was shown, not silently reattached to whatever state exists when
`answer` is called. Omitting --sha on `hold` keeps old behavior exactly (no --sha required on answer).

Batch holds -- for a batch dispatcher fanning out to several concurrent sub-supervisors (see SKILL.md's
fan-out section): ONE genuine human decision per batch, not one per task-id. `--entries-file PATH` points
at a JSON file: a list of {"task_id": ..., "checked_sha": ..., "checker_verdict_path": ...}, capped at
10 entries (the same hard, non-tunable N=10 concurrent-batch cap SKILL.md's fan-out section enforces).
Each entry's own `checked_sha` is carried in the hold record exactly like today's single-task `--sha`
(this is an EXTENSION of the schema, not a replacement -- a human explicitly chose to keep the existing
1:1 task-id:checked-sha anti-reattach binding, just per-entry instead of per-hold). Every entry's
`checker_verdict_path` MUST point at a real, readable, parseable verdict envelope -- a missing path, an
unreadable file, or one that doesn't contain the checker's documented envelope contract rejects the WHOLE
`hold` call (nonzero exit, no ledger write) rather than opening a hold with a placeholder digest behind
it; a human must never be able to approve/merge an entry with no real verdict artifact behind its
summary. For each entry, hold.py itself derives a one-line digest FROM that entry's own real, parsed
`checker_verdict_path` (never typed fresh by whoever opens the hold, so the human's summary is provably
sourced from the real verdict, never a paraphrase) -- more than a bare pass/fail + count: the verdict
word, the findings count, the distinct set of files those findings actually flagged (a faithful
blast-radius proxy -- the envelope has no explicit "blast radius" field, but the files its own findings
touch is the closest real signal it carries), and `lens_coverage` (the closest thing the envelope has to
a category/tag concept) -- everything read directly off the checker's own documented envelope contract
(bin/checker-envelope.md's fenced ```json {"verdict":..., "findings":[...], "lens_coverage":{...}} block).

`answer`ing a batch hold is likewise structured, matching dispatch-report.py's own anti-prose-parsing
philosophy: `--approve`/`--reject` are each a comma-separated list of task-ids, and together they must
classify every task-id in the hold's own entries exactly once (no missing, no duplicate, no unknown
task-id) -- rejected outright otherwise, appending nothing. A rejected task-id is recorded as rejected,
never silently dropped: whoever merges only merges the approved ones (see merge-sequencer.sh/SKILL.md);
a rejected task-id's claim stays open for rework, by construction, since this script never touches
claim-ledger.py at all.
"""
import json, sys, os, time, argparse, pathlib, hashlib, contextlib, io, tempfile, shutil, re
try:
    import fcntl
except ImportError:  # non-Unix (e.g. Windows) -> best-effort, no locking
    fcntl = None

LEDGER = pathlib.Path(os.environ.get("SM_HOLD_LEDGER", "decisions.jsonl"))
_BAD = 0  # count of malformed/incomplete ledger lines seen by the last _recs()

# task-id charset/length discipline mirrors claim-ledger.py's _TASK_ID_RE exactly -- a batch hold's
# entries key on the same task-ids claim-ledger.py/progress-ledger.py already validate.
_TASK_ID_RE = re.compile(r"\A[A-Za-z0-9_-]{1,128}\Z")


def _valid_task_id(task_id):
    return isinstance(task_id, str) and bool(_TASK_ID_RE.match(task_id))


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
            if o["ev"] == "answer":
                # a valid answer is EITHER the original single-task shape ("a" present) OR a batch-hold
                # answer ("approved"/"rejected" both present, as lists) -- an incomplete/mixed shape
                # must not close a hold (finding #1's original rationale, extended to the new shape).
                has_single = "a" in o
                has_batch = isinstance(o.get("approved"), list) and isinstance(o.get("rejected"), list)
                if not (has_single or has_batch):
                    _BAD += 1; continue
            recs.append(o)
        else:
            _BAD += 1
    return recs


def _extract_verdict_envelope(text):
    """Best-effort extraction of the checker's own DOCUMENTED envelope contract (bin/checker-envelope.md:
    a trailing fenced ```json {"verdict":..., "findings":[...]}` block). Digest-only -- never a merge/gate
    decision (that stays verdict.py's own job elsewhere in the SOP); this exists purely so a batch hold's
    one-line-per-task-id digest is machine-derived FROM the real verdict artifact, never typed fresh by
    whoever opens the hold. Prefers the LAST fenced json block (this repo's own "last block/line wins"
    precedent, e.g. verdict.py's fenced-JSON preference, dispatch-report.py's last-tag-wins rule); falls
    back to the last depth-0 balanced {...} object anywhere in the text that has a "verdict" key. Returns
    None if nothing in the text matches that contract at all."""
    fenced = re.findall(r"```json\s*(\{.*?\})\s*```", text, re.DOTALL)
    for block in reversed(fenced):
        try:
            o = json.loads(block)
        except ValueError:
            continue
        if isinstance(o, dict) and "verdict" in o:
            return o
    depth = 0; start = None; in_str = False; esc = False; spans = []
    for i, c in enumerate(text):
        if in_str:
            if esc: esc = False
            elif c == "\\": esc = True
            elif c == '"': in_str = False
            continue
        if c == '"': in_str = True
        elif c == "{":
            if depth == 0: start = i
            depth += 1
        elif c == "}" and depth > 0:
            depth -= 1
            if depth == 0 and start is not None:
                spans.append(text[start:i + 1])
    for span in reversed(spans):
        try:
            o = json.loads(span)
        except ValueError:
            continue
        if isinstance(o, dict) and "verdict" in o:
            return o
    return None


def _distinct_finding_files(findings):
    """Distinct file paths referenced by a checker's own findings list (its own documented `file:line`
    tokens, per bin/checker-envelope.md) -- a faithful blast-radius proxy sourced directly from the real
    envelope, never invented: the envelope format has no explicit "blast radius" field, but the SET OF
    FILES its findings actually touch is the closest real signal it does carry. Same path-vs-URL
    exclusion as verdict.py's own `_finding_has_location` (a candidate starting with '//' is a URL
    host:port, not a path)."""
    files = set()
    if not isinstance(findings, list):
        return files
    for f in findings:
        if not isinstance(f, str):
            continue
        for m in re.finditer(r'([^\s:]+):\d+', f):
            path = m.group(1)
            if path.startswith("//"):
                continue  # URL host:port, not a file path
            files.add(path)
    return files


def _build_digest(task_id, envelope):
    """Pure formatting of an ALREADY-PARSED, ALREADY-VALIDATED verdict envelope dict into one line --
    never fails, never touches a file (reading/parsing happens earlier in `hold`'s own --entries-file
    validation, where a failure there must reject the WHOLE hold call, never render a placeholder
    digest for a missing/unparseable verdict -- see that call site). Deliberately richer than a bare
    pass/fail + count: surfaces `lens_coverage` (the closest thing this envelope format has to a
    category/tag concept -- which lenses the checker itself reports having exercised) and the distinct
    set of files its own findings flagged (the blast-radius proxy from `_distinct_finding_files` above)
    -- both read directly off the real envelope, never invented."""
    verdict = envelope.get("verdict", "UNKNOWN")
    findings = envelope.get("findings")
    n = len(findings) if isinstance(findings, list) else 0
    files = _distinct_finding_files(findings)
    lens_coverage = envelope.get("lens_coverage")
    lenses = sorted(lens_coverage.keys()) if isinstance(lens_coverage, dict) else []
    return (f"{task_id}: verdict={verdict} findings={n} files={len(files)} "
            f"lenses={','.join(lenses) if lenses else 'none'}")


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


def _dupes(items):
    """Items appearing more than once in `items`, preserving nothing about order -- used to reject a
    batch answer's --approve/--reject lists outright rather than silently deduping them via a set."""
    seen = set(); dupes = set()
    for i in items:
        if i in seen:
            dupes.add(i)
        seen.add(i)
    return dupes


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
        code, out, _ = _run(["answer", did, "--a", "merge", "--sha", "deadbeef"])
        assert code == 0, "answer with matching --sha should succeed"
        assert did in {r["id"] for r in _recs() if r["ev"] == "answer"}, "matching-sha answer did not close the hold"
        assert "REMINDER" in out and "human" in out.lower(), "successful answer must print the genuine-human-decision reminder"

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

        # ---- batch holds ----
        vdir = pathlib.Path(tmpdir) / "verdicts"
        vdir.mkdir()
        v_pass = vdir / "pass.out"
        v_pass.write_text("some checker prose\n```json\n"
                           '{"verdict":"pass","findings":[],"diagnostic":""}' + "\n```\n")
        v_fail = vdir / "fail.out"
        v_fail.write_text("prose\n```json\n"
                           '{"verdict":"fail","findings":["a.py:1 bug","b.py:2 bug"],"diagnostic":""}'
                           + "\n```\nmore trailing prose after the fence\n")
        entries_file = pathlib.Path(tmpdir) / "entries.json"
        entries_file.write_text(json.dumps([
            {"task_id": "batch-a", "checked_sha": "sha-a", "checker_verdict_path": str(v_pass)},
            {"task_id": "batch-b", "checked_sha": "sha-b", "checker_verdict_path": str(v_fail)},
        ]))
        code, bdid, _ = _run(["hold", "--task", "batch-1", "--q", "merge batch?",
                               "--entries-file", str(entries_file)])
        assert code == 0, "a well-formed --entries-file batch hold should succeed"
        brec = next(r for r in _recs() if r["ev"] == "hold" and r["id"] == bdid)
        assert "sha" not in brec, "a batch hold must not carry a single top-level sha"
        assert len(brec["batch"]) == 2, "batch hold must carry both entries"
        digest_by_task = {e["task_id"]: e["digest"] for e in brec["batch"]}
        assert digest_by_task["batch-a"] == "batch-a: verdict=pass findings=0 files=0 lenses=none", (
            f"digest must be machine-derived from the real verdict envelope, got {digest_by_task['batch-a']!r}")
        assert digest_by_task["batch-b"] == "batch-b: verdict=fail findings=2 files=2 lenses=none", (
            f"digest must reflect the real findings count and the distinct files those findings flagged "
            f"(blast-radius proxy), got {digest_by_task['batch-b']!r}")

        # a digest with lens_coverage present must surface those lenses -- the closest thing the envelope
        # format has to a category/tag concept -- proving the digest is demonstrably richer than a bare
        # pass/fail + count, not just a differently-worded bare count.
        v_lens = vdir / "lens.out"
        v_lens.write_text("```json\n" +
                           '{"verdict":"fail","findings":["x.py:5 issue"],'
                           '"lens_coverage":{"risk-flagging":true,"qa/coverage":true}}' + "\n```\n")
        entries_lens = pathlib.Path(tmpdir) / "entries_lens.json"
        entries_lens.write_text(json.dumps([
            {"task_id": "batch-lens", "checked_sha": "sha-lens", "checker_verdict_path": str(v_lens)},
        ]))
        code, bdid_lens, _ = _run(["hold", "--task", "batch-lens-1", "--q", "merge?",
                                    "--entries-file", str(entries_lens)])
        assert code == 0
        brec_lens = next(r for r in _recs() if r["ev"] == "hold" and r["id"] == bdid_lens)
        assert brec_lens["batch"][0]["digest"] == (
            "batch-lens: verdict=fail findings=1 files=1 lenses=qa/coverage,risk-flagging"), (
            f"digest must surface lens_coverage's own lens names, got {brec_lens['batch'][0]['digest']!r}")

        # --entries-file and --sha are mutually exclusive.
        code, _, exc = _run(["hold", "--task", "t", "--q", "q", "--sha", "x",
                              "--entries-file", str(entries_file)])
        assert code != 0, "--entries-file and --sha together must be rejected"

        # a batch entry with NO checker_verdict_path must reject the WHOLE hold call -- no ledger write,
        # never a placeholder "UNKNOWN" digest. A human must never be able to approve/merge an entry with
        # no real verdict artifact behind its digest.
        entries_missing = pathlib.Path(tmpdir) / "entries_missing.json"
        entries_missing.write_text(json.dumps([
            {"task_id": "batch-nopath", "checked_sha": "sha-x"},
        ]))
        pre_len = len(_recs())
        code, _, exc = _run(["hold", "--task", "t", "--q", "q", "--entries-file", str(entries_missing)])
        assert code != 0, "a batch entry with no checker_verdict_path must be rejected"
        assert len(_recs()) == pre_len, "a rejected --entries-file hold must not append any record"

        # a checker_verdict_path that doesn't exist on disk must also reject the whole call.
        entries_unreadable = pathlib.Path(tmpdir) / "entries_unreadable.json"
        entries_unreadable.write_text(json.dumps([
            {"task_id": "batch-noread", "checked_sha": "sha-x",
             "checker_verdict_path": str(vdir / "does-not-exist.out")},
        ]))
        pre_len = len(_recs())
        code, _, exc = _run(["hold", "--task", "t", "--q", "q", "--entries-file", str(entries_unreadable)])
        assert code != 0, "an unreadable checker_verdict_path must be rejected"
        assert len(_recs()) == pre_len, "a rejected --entries-file hold must not append any record"

        # a checker_verdict_path whose content has no parseable verdict envelope must also reject the
        # whole call -- never render a placeholder "UNKNOWN" digest and open the hold anyway.
        v_bad = vdir / "unparseable.out"
        v_bad.write_text("no envelope here at all, just prose\n")
        entries_unparseable = pathlib.Path(tmpdir) / "entries_unparseable.json"
        entries_unparseable.write_text(json.dumps([
            {"task_id": "batch-c", "checked_sha": "sha-c", "checker_verdict_path": str(v_bad)},
        ]))
        pre_len = len(_recs())
        code, _, exc = _run(["hold", "--task", "t", "--q", "q", "--entries-file", str(entries_unparseable)])
        assert code != 0, "an unparseable checker_verdict_path must be rejected, never open a hold anyway"
        assert len(_recs()) == pre_len, "a rejected --entries-file hold must not append any record"

        # the hard, non-tunable N=10 concurrent-batch cap: 11 OTHERWISE-FULLY-VALID entries (real
        # checked_sha, real parseable checker_verdict_path each) must still be rejected outright -- every
        # entry here would individually pass every other validation, isolating the cap itself as the
        # only thing that can reject this batch (a weaker fixture with e.g. missing checker_verdict_path
        # would be rejected for the wrong reason even with the cap check removed entirely).
        entries_toomany = pathlib.Path(tmpdir) / "entries_toomany.json"
        entries_toomany.write_text(json.dumps(
            [{"task_id": f"cap-{i}", "checked_sha": "sha-x", "checker_verdict_path": str(v_pass)}
             for i in range(11)]))
        pre_len = len(_recs())
        code, _, exc = _run(["hold", "--task", "t", "--q", "q", "--entries-file", str(entries_toomany)])
        assert code != 0, "an --entries-file batch of 11 otherwise-valid entries must be rejected (N=10 hard cap)"
        assert len(_recs()) == pre_len, "a rejected over-cap --entries-file hold must not append any record"

        # a batch hold cannot be answered with --a.
        pre_len = len(_recs())
        code, _, exc = _run(["answer", bdid, "--a", "yes"])
        assert code != 0, "a batch hold must reject --a"
        assert len(_recs()) == pre_len, "a rejected batch answer must not append any record"

        # a batch hold's answer must classify EVERY entry -- missing one is rejected.
        code, _, exc = _run(["answer", bdid, "--approve", "batch-a"])
        assert code != 0, "an incomplete batch classification (missing batch-b) must be rejected"
        assert "batch-b" in str(exc), "the rejection should name the unclassified task-id"

        # an unknown task-id in --approve/--reject must be rejected.
        code, _, exc = _run(["answer", bdid, "--approve", "batch-a,batch-b,not-in-batch"])
        assert code != 0, "an unknown task-id in --approve must be rejected"

        # a task-id in BOTH --approve and --reject must be rejected.
        code, _, exc = _run(["answer", bdid, "--approve", "batch-a,batch-b", "--reject", "batch-a"])
        assert code != 0, "a task-id classified in both --approve and --reject must be rejected"

        # a DUPLICATE task-id WITHIN a single --approve (or --reject) list must be rejected outright --
        # never silently deduped via a set, which would corrupt an otherwise-auditable classification.
        code, _, exc = _run(["answer", bdid, "--approve", "batch-a,batch-a", "--reject", "batch-b"])
        assert code != 0, "a duplicate task-id within --approve must be rejected"
        assert "batch-a" in str(exc), "the rejection should name the duplicated task-id"
        code, _, exc = _run(["answer", bdid, "--approve", "batch-a", "--reject", "batch-b,batch-b"])
        assert code != 0, "a duplicate task-id within --reject must be rejected"
        assert "batch-b" in str(exc), "the rejection should name the duplicated task-id"

        # the real, complete classification succeeds and records structured approved/rejected lists.
        code, out, _ = _run(["answer", bdid, "--approve", "batch-a", "--reject", "batch-b"])
        assert code == 0, "a complete, non-overlapping batch classification must succeed"
        assert "1 approved" in out and "1 rejected" in out, "the reminder should summarize the split"
        arec = next(r for r in _recs() if r["ev"] == "answer" and r["id"] == bdid)
        assert arec["approved"] == ["batch-a"] and arec["rejected"] == ["batch-b"], (
            "batch answer must record structured approved/rejected lists, not freeform prose")
        assert bdid not in {r["id"] for r in open_decisions()}, "an answered batch hold must no longer be open"

        # a SINGLE-task hold must reject --approve/--reject.
        code, did4, _ = _run(["hold", "--task", "t", "--q", "single again"])
        assert code == 0
        code, _, exc = _run(["answer", did4, "--approve", "whatever"])
        assert code != 0, "a single-task hold must reject --approve/--reject"

        # `open` must render a batch hold's per-task-id entries (task-id, checked_sha, digest), not just
        # its top-level question.
        code, out, _ = _run(["open"])
        assert "batch-lens" in out and "sha-lens" in out and "qa/coverage" in out, (
            "open must surface a batch hold's per-task-id entries, not just its top-level question")
    finally:
        LEDGER = orig_ledger
        shutil.rmtree(tmpdir, ignore_errors=True)


def main(argv):
    p = argparse.ArgumentParser(description="durable human-gate decisions")
    sub = p.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("hold"); h.add_argument("--task", required=True); h.add_argument("--q", required=True); h.add_argument("--opts", default=""); h.add_argument("--sha", default=""); h.add_argument("--entries-file", default="")
    a = sub.add_parser("answer"); a.add_argument("id"); a.add_argument("--a", default=None); a.add_argument("--sha", default=""); a.add_argument("--approve", default=None); a.add_argument("--reject", default=None)
    sub.add_parser("open"); sub.add_parser("next"); sub.add_parser("selfcheck")
    args = p.parse_args(argv)

    if args.cmd == "hold":
        if args.entries_file and args.sha:
            sys.exit("--entries-file (a consolidated batch hold) and --sha (a single-task hold) are "
                      "mutually exclusive -- a batch hold carries its own per-entry checked-sha instead")
        batch = None
        if args.entries_file:
            try:
                raw = json.loads(pathlib.Path(args.entries_file).read_text())
            except (OSError, ValueError) as e:
                sys.exit(f"--entries-file {args.entries_file!r} could not be read/parsed as JSON: {e}")
            if not isinstance(raw, list) or not raw:
                sys.exit(f"--entries-file {args.entries_file!r} must contain a non-empty JSON list of entries")
            if len(raw) > 10:
                sys.exit(f"--entries-file has {len(raw)} entries, exceeding the hard, non-tunable "
                          f"N=10 concurrent-batch cap")
            batch = []
            seen_ids = set()
            for i, entry in enumerate(raw):
                if not isinstance(entry, dict):
                    sys.exit(f"--entries-file entry #{i} is not a JSON object")
                tid = entry.get("task_id")
                if not _valid_task_id(tid):
                    sys.exit(f"--entries-file entry #{i} has an invalid or missing task_id {tid!r}")
                if tid in seen_ids:
                    sys.exit(f"--entries-file has a duplicate task_id {tid!r}")
                seen_ids.add(tid)
                csha = entry.get("checked_sha")
                if not csha or not isinstance(csha, str):
                    sys.exit(f"--entries-file entry for task_id {tid!r} is missing a non-empty checked_sha")
                # every batch entry MUST have a real, parseable verdict artifact behind its digest -- a
                # human must never be able to approve/merge an entry whose digest was never actually
                # sourced from anything (see _build_digest's own docstring for why this validation lives
                # HERE, before any ledger write, rather than inside a "never fails" digest builder).
                cvp = entry.get("checker_verdict_path")
                if not cvp or not isinstance(cvp, str):
                    sys.exit(f"--entries-file entry for task_id {tid!r} is missing a checker_verdict_path "
                              f"-- every batch entry must have a real verdict artifact behind its digest")
                try:
                    text = pathlib.Path(cvp).read_text(errors="replace")
                except OSError as e:
                    sys.exit(f"--entries-file entry for task_id {tid!r}: checker_verdict_path {cvp!r} "
                              f"could not be read: {e}")
                envelope = _extract_verdict_envelope(text)
                if envelope is None:
                    sys.exit(f"--entries-file entry for task_id {tid!r}: checker_verdict_path {cvp!r} "
                              f"does not contain a parseable verdict envelope -- refusing to open a hold "
                              f"with no real verdict behind it")
                digest = _build_digest(tid, envelope)
                batch.append({"task_id": tid, "checked_sha": csha, "digest": digest})
        with _ledger_lock():
            ts = time.strftime("%Y-%m-%dT%H:%M:%S")
            extra = args.sha if batch is None else json.dumps(sorted(e["task_id"] for e in batch))
            did = _mkid(args.task, args.q, ts, extra)
            rec = {"ev": "hold", "id": did, "ts": ts, "task": args.task, "q": args.q,
                   "opts": [o for o in args.opts.split("|") if o]}
            if args.sha:   # only add the key when given, so old ledgers with no "sha" key stay the same shape
                rec["sha"] = args.sha
            if batch is not None:
                rec["batch"] = batch
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
            hold_rec = hold_by_id[args.id]
            batch = hold_rec.get("batch")
            if batch is not None:
                if args.a is not None:
                    sys.exit(f"decision {args.id} is a consolidated BATCH hold -- answer it with "
                              f"--approve/--reject, not --a")
                if args.sha:
                    sys.exit(f"decision {args.id} is a consolidated BATCH hold -- it has no single "
                              f"top-level sha to match (each entry already carries its own checked_sha)")
                # LISTS, not sets -- a duplicate within one list (or split across both) must be REJECTED,
                # never silently coerced away by a set's own dedup. Every task-id must be classified
                # EXACTLY once for this to be an auditable, unambiguous decision.
                approve_list = [t for t in (args.approve or "").split(",") if t]
                reject_list = [t for t in (args.reject or "").split(",") if t]
                approve_dupes = _dupes(approve_list)
                if approve_dupes:
                    sys.exit(f"decision {args.id}: task-id(s) {sorted(approve_dupes)} appear more than "
                              f"once in --approve")
                reject_dupes = _dupes(reject_list)
                if reject_dupes:
                    sys.exit(f"decision {args.id}: task-id(s) {sorted(reject_dupes)} appear more than "
                              f"once in --reject")
                approve_ids = set(approve_list)
                reject_ids = set(reject_list)
                batch_ids = {e["task_id"] for e in batch}
                overlap = approve_ids & reject_ids
                if overlap:
                    sys.exit(f"decision {args.id}: task-id(s) {sorted(overlap)} appear in BOTH "
                              f"--approve and --reject")
                unknown = (approve_ids | reject_ids) - batch_ids
                if unknown:
                    sys.exit(f"decision {args.id}: task-id(s) {sorted(unknown)} are not part of this "
                              f"batch hold's entries")
                missing = batch_ids - (approve_ids | reject_ids)
                if missing:
                    sys.exit(f"decision {args.id}: task-id(s) {sorted(missing)} were not classified -- "
                              f"every task-id in the batch must be approved or rejected")
                ts = time.strftime("%Y-%m-%dT%H:%M:%S")
                _append({"ev": "answer", "id": args.id, "ts": ts,
                         "approved": sorted(approve_ids), "rejected": sorted(reject_ids)})
            else:
                if args.a is None:
                    sys.exit(f"decision {args.id} is a single-task hold -- answer it with --a")
                if args.approve is not None or args.reject is not None:
                    sys.exit(f"decision {args.id} is a single-task hold -- it does not take "
                              f"--approve/--reject")
                # finding: a hold created with --sha binds the id to that state; answer must match it
                # exactly, so a human's decision can't be silently reattached to a later, different code
                # state.
                hold_sha = hold_rec.get("sha")
                if hold_sha and args.sha != hold_sha:
                    sys.exit(f"decision {args.id} was held at sha {hold_sha}, but answer supplied sha "
                             f"{args.sha or '(none)'} -- refusing to attach an answer to a different code state")
                _append({"ev": "answer", "id": args.id, "ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "a": args.a})
        # advisory echo, printed only on a successful answer -- a self-answered hold (no genuine human
        # behind the decision) is a real, recorded incident class (searchable via
        # `bin/audit-log.py search "self-answered"`); this can't verify who is actually at the
        # keyboard, it can only remind whoever ran this command.
        if batch is not None:
            print(f"REMINDER: decision {args.id} is now answered ({len(approve_ids)} approved, "
                  f"{len(reject_ids)} rejected) -- this should represent a genuine human decision, not a "
                  f"self-answered hold (see audit/decision/ via bin/audit-log.py search for past "
                  f"incidents of that).")
        else:
            print(f"REMINDER: decision {args.id} is now answered -- this should represent a genuine human "
                  f"decision, not a self-answered hold (see audit/decision/ via bin/audit-log.py search "
                  f"for past incidents of that).")
    elif args.cmd == "open":
        rows = open_decisions()
        if not rows and _BAD == 0:
            print("(no open decisions)", file=sys.stderr)  # stderr: keeps SessionStart-hook stdout clean when empty
        for r in rows:
            opts = r.get("opts") or []
            print(f"[{r['id']}] ({r.get('task', '?')}) {r.get('q', '?')}" + (f"   opts: {', '.join(opts)}" if opts else ""))
            for e in (r.get("batch") or []):
                print(f"    - {e['task_id']} (checked_sha={e['checked_sha']}) {e['digest']}")
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
        for e in (row.get("batch") or []):
            print(f"    - {e['task_id']} (checked_sha={e['checked_sha']}) {e['digest']}")
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
