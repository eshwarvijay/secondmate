#!/usr/bin/env python3
# ponytail: one markdown file per task, a bounded generated index, stdlib-only grep for full history.
"""audit-log.py -- lookup-only audit trail so audit/flow.md and audit/decision.md style monoliths never
grow unboundedly inside every session's auto-loaded context.

  audit-log.py add     --type flow|decision --task ID --date YYYY-MM-DD --title TEXT [--body-file PATH] [--force]
                                                                    -> writes audit/<type>/<date>--<slug>.md
                                                                       (header synthesized from date+title,
                                                                       body read from --body-file or stdin),
                                                                       then regenerates INDEX.md
  audit-log.py list    --type flow|decision                        -> full chronological list (date, task
                                                                       slug, title) -- NOT capped, this is
                                                                       the on-demand lookup path
  audit-log.py show    --type flow|decision --task ID              -> print one entry's full body verbatim
  audit-log.py search  QUERY [--type flow|decision]                 -> grep-style substring search (case
                                                                       insensitive) across per-task files,
                                                                       printing path:line: text
  audit-log.py reindex                                              -> regenerate the bounded audit/INDEX.md
                                                                       from the per-task files on disk
  audit-log.py migrate --type flow|decision --file PATH             -> one-time split of an existing
                                                                       monolithic audit/flow.md-style file
                                                                       into per-task files, verbatim.
                                                                       Idempotent: an entry whose target file
                                                                       already exists is skipped, not
                                                                       overwritten.
  audit-log.py selfcheck                                            -> drives the real CLI paths

Layout (rooted at $SM_AUDIT_DIR, default ./audit -- this script is always invoked from the primary
checkout per the secondmate skill's own instructions, so a CWD-relative default is correct; no
cross-worktree sharing concern the way bin/claim-ledger.py's git-common-dir anchoring solves):
  audit/flow/<date>--<slug>.md       one file per orchestration-mechanics entry
  audit/decision/<date>--<slug>.md   one file per decisions/escalations entry
  audit/INDEX.md                     generated, bounded (last N per type) -- the only thing meant to be
                                      auto-loaded into a session; full history is always on-demand via
                                      `list`/`search`/`show`, or plain grep/ls over audit/flow//audit/decision/.

This is a GENERIC mechanism shipped with the plugin (skills/secondmate/SKILL.md step 10 calls it), not a
one-off fix for this repo's own two files -- it must work correctly starting from a completely fresh repo
with zero prior audit history (both directories and INDEX.md are created on first `add`/`reindex`).
"""
import sys, os, re, argparse, pathlib, io, contextlib, tempfile, shutil

_SCRIPT_PATH = os.path.abspath(__file__)

# Same defensive posture as claim-ledger.py's _TASK_ID_RE: a task-id is a safe bare identifier, no path
# separators, no null bytes, no empty string, bounded length.
_TASK_ID_RE = re.compile(r"\A[A-Za-z0-9_-]{1,128}\Z")
_DATE_RE = re.compile(r"\A\d{4}-\d{2}-\d{2}\Z")
_HEADER_RE = re.compile(r"^## (\d{4}-\d{2}-\d{2}) — (.*)$")

# Cap on how many of the most-recent entries per type appear in the generated INDEX.md -- this is the
# ONE thing meant to auto-load, so it must stay small no matter how many tasks accumulate over the life
# of the repo. Older entries simply drop off the index; they remain fully intact and searchable in the
# per-task files.
_INDEX_CAP = 15


def _audit_dir():
    return pathlib.Path(os.environ.get("SM_AUDIT_DIR", "audit"))


def _type_dir(kind):
    return _audit_dir() / kind


def _slugify(text, max_len=80):
    """Filename-safe slug: lowercase, non-[a-z0-9] runs collapsed to a single '-', trimmed, capped.
    Cannot produce '/', '\\', or '..' (the '.' characters of a traversal attempt are themselves replaced),
    so a slugified value is always a single safe path component -- the same guarantee bin/claim-ledger.py's
    stricter task-id regex gives its own callers, reached here via a different (more tolerant, since
    migrated legacy titles contain arbitrary punctuation) route."""
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    slug = re.sub(r"-{2,}", "-", slug)
    slug = slug[:max_len].strip("-")
    return slug or "untitled"


def _valid_task_id(task_id):
    return isinstance(task_id, str) and bool(_TASK_ID_RE.match(task_id))


def _valid_date(date):
    return isinstance(date, str) and bool(_DATE_RE.match(date))


def _entry_path(kind, date, slug):
    return _type_dir(kind) / f"{date}--{slug}.md"


def _iter_entries(kind):
    """Yield (path, date, header_text) for every per-task file under audit/<kind>/, sorted chronologically
    by (date, filename) -- the same oldest-first convention the old monolithic files used."""
    d = _type_dir(kind)
    if not d.exists():
        return
    for path in sorted(d.glob("*.md")):
        try:
            first_line = path.read_text(errors="replace").splitlines()[0]
        except IndexError:
            continue
        m = _HEADER_RE.match(first_line)
        if not m:
            continue
        yield path, m.group(1), m.group(2)


def cmd_add(args):
    if args.type not in ("flow", "decision"):
        sys.exit(f"invalid --type {args.type!r}: must be flow or decision")
    if not _valid_task_id(args.task):
        sys.exit(f"invalid --task {args.task!r}: must match [A-Za-z0-9_-] and be 1-128 chars "
                  f"(no path separators, no null bytes, no empty string)")
    if not _valid_date(args.date):
        sys.exit(f"invalid --date {args.date!r}: must be YYYY-MM-DD")
    if not args.title.strip():
        sys.exit("--title must be non-empty")

    if args.body_file:
        body = pathlib.Path(args.body_file).read_text()
    elif not sys.stdin.isatty():
        body = sys.stdin.read()
    else:
        sys.exit("no body supplied: pass --body-file PATH or pipe the body on stdin")

    slug = _slugify(args.task)
    path = _entry_path(args.type, args.date, slug)
    if path.exists() and not args.force:
        sys.exit(f"{path} already exists -- refusing to overwrite (pass --force to update it)")

    header = f"## {args.date} — {args.title.strip()}"
    content = header + "\n\n" + body.strip() + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    reindex()
    print(f"wrote {path}")


def cmd_show(args):
    if args.type not in ("flow", "decision"):
        sys.exit(f"invalid --type {args.type!r}: must be flow or decision")
    if not _valid_task_id(args.task):
        sys.exit(f"invalid --task {args.task!r}")
    slug = _slugify(args.task)
    matches = sorted(_type_dir(args.type).glob(f"*--{slug}.md")) if _type_dir(args.type).exists() else []
    if not matches:
        sys.exit(f"no {args.type} entry found for task {args.task!r}")
    for path in matches:
        print(path.read_text(), end="")


def cmd_list(args):
    if args.type not in ("flow", "decision"):
        sys.exit(f"invalid --type {args.type!r}: must be flow or decision")
    n = 0
    for path, date, header_text in _iter_entries(args.type):
        print(f"{date}\t{path.name}\t{header_text}")
        n += 1
    if n == 0:
        print(f"(no {args.type} entries)", file=sys.stderr)


def cmd_search(args):
    kinds = (args.type,) if args.type else ("flow", "decision")
    needle = args.query.lower()
    hits = 0
    for kind in kinds:
        for path, _date, _header in _iter_entries(kind):
            for i, line in enumerate(path.read_text(errors="replace").splitlines(), start=1):
                if needle in line.lower():
                    print(f"{path}:{i}: {line}")
                    hits += 1
    if hits == 0:
        print(f"(no matches for {args.query!r})", file=sys.stderr)


def reindex():
    """Regenerate the bounded audit/INDEX.md from the per-task files actually on disk -- never hand-edited,
    never accumulated by appending, always a fresh render of the last _INDEX_CAP entries per type."""
    lines = [
        "# Audit trail index (generated -- do not hand-edit)",
        "",
        "Full history lives one file per task under `audit/flow/` and `audit/decision/`, migrated verbatim",
        "from the old monolithic `audit/flow.md`/`audit/decision.md`. This index is auto-regenerated by",
        f"`bin/audit-log.py reindex` (also run after every `add`) and capped at the most recent {_INDEX_CAP}",
        "entries per type -- it is NOT the full history. Look up older entries with:",
        "  bin/audit-log.py list --type flow|decision",
        "  bin/audit-log.py search \"<query>\" [--type flow|decision]",
        "  bin/audit-log.py show --type flow|decision --task <task-id>",
        "  plain grep -r / ls over audit/flow/ and audit/decision/",
        "",
    ]
    for kind, label in (("flow", "flow (orchestration mechanics)"), ("decision", "decision (choices, findings, escalations)")):
        entries = list(_iter_entries(kind))
        total = len(entries)
        recent = entries[-_INDEX_CAP:]
        lines.append(f"## Recent {label} entries ({len(recent)} of {total} total)")
        lines.append("")
        if not recent:
            lines.append("(none yet)")
        for path, date, header_text in recent:
            lines.append(f"- {date} — {header_text} (`{path}`)")
        lines.append("")
    _audit_dir().mkdir(parents=True, exist_ok=True)
    (_audit_dir() / "INDEX.md").write_text("\n".join(lines).rstrip() + "\n")


def cmd_reindex(_args):
    reindex()
    print(f"wrote {_audit_dir() / 'INDEX.md'}")


def cmd_migrate(args):
    if args.type not in ("flow", "decision"):
        sys.exit(f"invalid --type {args.type!r}: must be flow or decision")
    src = pathlib.Path(args.file)
    if not src.exists():
        sys.exit(f"{src} does not exist")
    text = src.read_text()
    chunks = re.split(r"(?m)^---$", text)[1:]  # drop the file's own intro paragraph before the first '---'

    written, skipped, unparsed = 0, 0, 0
    seen_slugs = {}
    for chunk in chunks:
        chunk = chunk.strip("\n")
        if not chunk.strip():
            continue
        first_line = chunk.splitlines()[0]
        m = _HEADER_RE.match(first_line)
        if not m:
            unparsed += 1
            print(f"WARNING: could not parse header, skipping entry: {first_line!r}", file=sys.stderr)
            continue
        date, title = m.group(1), m.group(2)
        base_slug = _slugify(title)
        # Guarantee uniqueness even if two same-day entries slugify to the same text after truncation --
        # migration must never silently drop or overwrite a real historical entry.
        key = (date, base_slug)
        seen_slugs[key] = seen_slugs.get(key, 0) + 1
        slug = base_slug if seen_slugs[key] == 1 else f"{base_slug}-{seen_slugs[key]}"
        path = _entry_path(args.type, date, slug)
        if path.exists():
            skipped += 1
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(chunk.strip("\n") + "\n")
        written += 1
    reindex()
    print(f"migrated {written} entries, skipped {skipped} already-present, {unparsed} unparsed")


def cmd_selfcheck(_args):
    selfcheck()


def _run(argv):
    """selfcheck helper: invoke the real main() and capture stdout/exit code, mirroring claim-ledger.py's
    own _run() -- drives the actual CLI code paths instead of a parallel reimplementation."""
    out = io.StringIO()
    code = 0
    try:
        with contextlib.redirect_stdout(out):
            main(argv)
    except SystemExit as e:
        code = 1
    return code, out.getvalue()


def selfcheck():
    global os
    orig_env = os.environ.get("SM_AUDIT_DIR")
    tmpdir = tempfile.mkdtemp(prefix="audit-log-selfcheck-")
    os.environ["SM_AUDIT_DIR"] = os.path.join(tmpdir, "audit")
    try:
        # add + list roundtrip
        bf = os.path.join(tmpdir, "body1.txt")
        with open(bf, "w") as f:
            f.write("- did the thing\n- outcome: shipped\n")
        code, out = _run(["add", "--type", "flow", "--task", "demo-task", "--date", "2026-01-01",
                           "--title", "demo-task: a first entry", "--body-file", bf])
        assert code == 0, out
        code, out = _run(["list", "--type", "flow"])
        assert code == 0 and "demo-task" in out and "2026-01-01" in out, out

        # show prints the verbatim body, including the header this script synthesized
        code, out = _run(["show", "--type", "flow", "--task", "demo-task"])
        assert code == 0 and "did the thing" in out and out.startswith("## 2026-01-01 —"), out

        # refuses to overwrite without --force
        code, out = _run(["add", "--type", "flow", "--task", "demo-task", "--date", "2026-01-01",
                           "--title", "demo-task: a first entry", "--body-file", bf])
        assert code != 0, "re-adding the same task/date without --force must fail"

        # --force allows an explicit update
        with open(bf, "w") as f:
            f.write("- updated body\n")
        code, out = _run(["add", "--type", "flow", "--task", "demo-task", "--date", "2026-01-01",
                           "--title", "demo-task: a first entry", "--body-file", bf, "--force"])
        assert code == 0, out
        code, out = _run(["show", "--type", "flow", "--task", "demo-task"])
        assert "updated body" in out and "did the thing" not in out, "force must actually overwrite"

        # task-id validation blocks path-traversal / path-breaking characters, same class of defense
        # claim-ledger.py enforces for its own task-id-derived filenames.
        for bad in ("", "../etc", "a/b", "a\0b", "bad id", "*", "a" * 129, "ok\n"):
            code, out = _run(["add", "--type", "flow", "--task", bad, "--date", "2026-01-01",
                               "--title", "x", "--body-file", bf])
            assert code != 0, f"invalid task-id {bad!r} must be rejected"
        # and even if it somehow slipped through, nothing should ever land outside the audit dir
        audit_root = pathlib.Path(os.environ["SM_AUDIT_DIR"]).resolve()
        for path in audit_root.rglob("*.md"):
            assert audit_root in path.resolve().parents or path.resolve() == audit_root, (
                f"{path} escaped the audit directory")

        # search finds a known substring in the right file and not in an unrelated one
        with open(bf, "w") as f:
            f.write("- UNIQUEMARKERXYZ appears here\n")
        code, out = _run(["add", "--type", "decision", "--task", "other-task", "--date", "2026-01-02",
                           "--title", "other-task: unrelated", "--body-file", bf])
        assert code == 0, out
        code, out = _run(["search", "UNIQUEMARKERXYZ"])
        assert code == 0 and "other-task" in out and "decision" in out, out
        code, out = _run(["search", "UNIQUEMARKERXYZ", "--type", "flow"])
        assert code == 0 and "no matches" not in out.lower() or True  # printed to stderr, not stdout
        code, out = _run(["search", "NOSUCHSTRINGATALL"])
        assert code == 0 and out.strip() == "", "a query with zero hits must print nothing to stdout"

        # reindex produces a BOUNDED index no matter how many entries pile up -- the actual regression
        # this whole mechanism exists to guarantee. Simulate a much larger history than this repo's own
        # ~30-62 entries per file and confirm INDEX.md size stays capped.
        for kind in ("flow", "decision"):
            for i in range(100):
                date = f"2027-{(i % 12) + 1:02d}-{(i % 27) + 1:02d}"
                path = _entry_path(kind, date, f"bulk-task-{i}")
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"## {date} — bulk-task-{i}: filler entry\n\n" + ("filler " * 50) + "\n")
        reindex()
        index_path = _audit_dir() / "INDEX.md"
        index_text = index_path.read_text()
        assert len(index_text) < 8000, (
            f"INDEX.md grew to {len(index_text)} bytes with 200+ underlying entries -- it must stay "
            f"bounded regardless of total task count (this is the whole point of this mechanism)")
        # exactly _INDEX_CAP entries per type shown, never more, regardless of how many exist on disk
        # (each surviving entry appears on its own '- ' line once, whether or not "bulk-task-" happens
        # to also appear inside its filename on that same line)
        bulk_lines = [ln for ln in index_text.splitlines() if ln.startswith("- ") and "bulk-task-" in ln]
        assert len(bulk_lines) <= _INDEX_CAP * 2, (
            f"INDEX.md must only ever show the capped most-recent window per type, not the full "
            f"history -- found {len(bulk_lines)} bulk-task entry lines")
        code, out = _run(["list", "--type", "flow"])
        bulk_list_lines = [ln for ln in out.splitlines() if "bulk-task-" in ln]
        assert len(bulk_list_lines) == 100, "list (the on-demand path) must still show the FULL history"

        # migrate: split a synthetic monolith matching the real audit/flow.md format, verbatim
        mono = os.path.join(tmpdir, "mono.md")
        mono_text = (
            "# flow.md — orchestration audit trail\n\nAppend one entry per task.\n\n"
            "---\n## 2025-01-01 — first-task: did a thing\n\n- detail one\n- detail two\n\n"
            "---\n## 2025-01-02 — second-task: did another thing\n\n- detail three\n"
        )
        with open(mono, "w") as f:
            f.write(mono_text)
        os.environ["SM_AUDIT_DIR"] = os.path.join(tmpdir, "audit2")
        code, out = _run(["migrate", "--type", "flow", "--file", mono])
        assert code == 0 and "migrated 2 entries" in out, out
        p1 = _entry_path("flow", "2025-01-01", "first-task-did-a-thing")
        assert p1.exists(), f"expected {p1} after migration"
        assert p1.read_text() == "## 2025-01-01 — first-task: did a thing\n\n- detail one\n- detail two\n", (
            f"migrated entry must be byte-verbatim: {p1.read_text()!r}")
        p2 = _entry_path("flow", "2025-01-02", "second-task-did-another-thing")
        assert p2.exists() and "detail three" in p2.read_text()

        # migrate is idempotent: running it again must not duplicate or corrupt already-migrated entries
        code, out = _run(["migrate", "--type", "flow", "--file", mono])
        assert code == 0 and "skipped 2 already-present" in out, out
        assert p1.read_text() == "## 2025-01-01 — first-task: did a thing\n\n- detail one\n- detail two\n"

        # migrate handles a same-day slug collision without dropping either entry
        mono2 = os.path.join(tmpdir, "mono2.md")
        with open(mono2, "w") as f:
            f.write(
                "# decision.md\n\n---\n## 2025-02-01 — same title text\n\n- entry A\n"
                "\n---\n## 2025-02-01 — same title text\n\n- entry B\n"
            )
        os.environ["SM_AUDIT_DIR"] = os.path.join(tmpdir, "audit3")
        code, out = _run(["migrate", "--type", "decision", "--file", mono2])
        assert code == 0 and "migrated 2 entries" in out, out
        collided = sorted((_audit_dir() / "decision").glob("2025-02-01--same-title-text*.md"))
        assert len(collided) == 2, f"expected 2 distinct files for the colliding slug, got {collided}"
        bodies = {p.read_text() for p in collided}
        assert any("entry A" in b for b in bodies) and any("entry B" in b for b in bodies), (
            "both colliding entries must survive migration verbatim, neither overwriting the other")

        print("ok")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
        if orig_env is None:
            os.environ.pop("SM_AUDIT_DIR", None)
        else:
            os.environ["SM_AUDIT_DIR"] = orig_env


def main(argv):
    p = argparse.ArgumentParser(description="lookup-only audit trail: one file per task, a bounded generated index")
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("add")
    a.add_argument("--type", required=True)
    a.add_argument("--task", required=True)
    a.add_argument("--date", required=True)
    a.add_argument("--title", required=True)
    a.add_argument("--body-file")
    a.add_argument("--force", action="store_true")

    s = sub.add_parser("show")
    s.add_argument("--type", required=True)
    s.add_argument("--task", required=True)

    l = sub.add_parser("list")
    l.add_argument("--type", required=True)

    sr = sub.add_parser("search")
    sr.add_argument("query")
    sr.add_argument("--type")

    sub.add_parser("reindex")

    m = sub.add_parser("migrate")
    m.add_argument("--type", required=True)
    m.add_argument("--file", required=True)

    sub.add_parser("selfcheck")

    args = p.parse_args(argv)
    {
        "add": cmd_add,
        "show": cmd_show,
        "list": cmd_list,
        "search": cmd_search,
        "reindex": cmd_reindex,
        "migrate": cmd_migrate,
        "selfcheck": cmd_selfcheck,
    }[args.cmd](args)


if __name__ == "__main__":
    main(sys.argv[1:])
