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

# Cap on how much of a single entry's TITLE is rendered into its INDEX.md line. An entry-count cap alone
# does not bound an individual title's length -- an unusually long --title would otherwise blow up
# INDEX.md regardless of _INDEX_CAP. The full, untruncated title always stays in the per-task file
# itself; only the generated index line is bounded.
_INDEX_TITLE_MAX = 120


def _truncate(text, max_len=_INDEX_TITLE_MAX):
    """Truncate to AT MOST max_len characters total, ellipsis included -- reserve room for the "..."
    within the cap rather than appending it on top, and floor at max_len itself for a very small cap
    where there's no room left for an ellipsis at all."""
    if len(text) <= max_len:
        return text
    keep = max(0, max_len - 3)
    return (text[:keep].rstrip() + "...")[:max_len]


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


def _task_component(task_id):
    """Filename component derived directly from an ALREADY-VALIDATED task-id (see _valid_task_id) --
    case-normalized (lowercased) but otherwise used AS-IS, never routed through _slugify()'s lossy
    collapse of '_' and '-' into the same separator. _slugify() exists for arbitrary, unconstrained
    TITLE text (used by migrate, for legacy entries that never had a discrete task-id); a validated
    task-id is already a safe, unique-as-typed bare identifier ([A-Za-z0-9_-]{1,128}, no path
    separators, no NUL, no '..') and needs no further lossy transformation -- two different, equally
    valid task-ids (e.g. 'a_b' and 'a-b') must never collide on the same derived filename."""
    return task_id.lower()


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

    slug = _task_component(args.task)
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
    # Substring match against the filename's slug, not an exact suffix -- migrated legacy entries are
    # named after their (slugified) TITLE, not a discrete task-id (they never had one), so a short
    # task-id-shaped query must still find an entry whose real filename slug is the full title. May
    # legitimately match more than one file; print every match, never silently pick one. Uses
    # _task_component (not _slugify) so a query like 'a_b' can't accidentally also match a distinct
    # 'a-b' entry's filename.
    needle = _task_component(args.task)
    d = _type_dir(args.type)
    matches = sorted(p for p in d.glob("*.md") if needle in p.stem) if d.exists() else []
    if not matches:
        sys.exit(f"no {args.type} entry found matching task {args.task!r}")
    for i, path in enumerate(matches):
        if len(matches) > 1:
            if i:
                print()
            print(f"=== {path} ===")
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
    if args.type is not None and args.type not in ("flow", "decision"):
        sys.exit(f"invalid --type {args.type!r}: must be flow or decision")
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
            lines.append(f"- {date} — {_truncate(header_text)} (`{path}`)")
        lines.append("")
    _audit_dir().mkdir(parents=True, exist_ok=True)
    (_audit_dir() / "INDEX.md").write_text("\n".join(lines).rstrip() + "\n")


def cmd_reindex(_args):
    reindex()
    print(f"wrote {_audit_dir() / 'INDEX.md'}")


def _split_monolith_entries(text):
    """Split a monolithic audit/flow.md-style file into (date, title, chunk_text) tuples by finding
    entry HEADERS (lines matching _HEADER_RE), never by splitting on bare '---' lines -- a markdown
    horizontal rule is ordinary body text and can legitimately appear inside a real entry, so treating
    every '---' as a boundary would silently truncate that entry's own content. Each entry's content
    runs from its own header line up to (but not including) the next header line, or EOF. Only when
    there IS a next entry is a trailing '---'-only separator line (plus surrounding blank lines)
    immediately before that next header stripped, since THAT belongs to the monolith's own formatting,
    not the entry -- for the LAST entry (no next header), everything from its own header to EOF is kept
    exactly as sliced, since any trailing '---' or lack of a final newline there is the entry's own real
    content/byte-shape, not a separator. Operates on `text` exactly as read (see cmd_migrate's
    newline="" open) so line endings, and the presence or absence of a final newline, are preserved
    verbatim in the returned chunk_text."""
    lines = text.splitlines(keepends=True)
    header_positions = []
    for i, line in enumerate(lines):
        m = _HEADER_RE.match(line.rstrip("\r\n"))
        if m:
            header_positions.append((i, m.group(1), m.group(2)))
    entries = []
    for idx, (start, date, title) in enumerate(header_positions):
        has_next = idx + 1 < len(header_positions)
        end = header_positions[idx + 1][0] if has_next else len(lines)
        chunk_lines = list(lines[start:end])
        if has_next:
            while chunk_lines and chunk_lines[-1].strip() == "":
                chunk_lines.pop()
            if chunk_lines and chunk_lines[-1].strip() == "---":
                chunk_lines.pop()
                while chunk_lines and chunk_lines[-1].strip() == "":
                    chunk_lines.pop()
        chunk_text = "".join(chunk_lines)
        entries.append((date, title, chunk_text))
    return entries


def cmd_migrate(args):
    if args.type not in ("flow", "decision"):
        sys.exit(f"invalid --type {args.type!r}: must be flow or decision")
    src = pathlib.Path(args.file)
    if not src.exists():
        sys.exit(f"{src} does not exist")
    # newline="" disables Python's universal-newline translation on both read and write, so a CRLF-
    # encoded source is migrated byte-verbatim rather than silently rewritten with LF-only endings.
    with open(src, "r", newline="") as f:
        text = f.read()
    entries = _split_monolith_entries(text)
    if not entries:
        print(f"WARNING: no entries found (no '## YYYY-MM-DD — title' header line) in {src}", file=sys.stderr)

    written, skipped, unparsed = 0, 0, 0
    seen_slugs = {}
    for date, title, chunk_text in entries:
        base_slug = _slugify(title)
        key = (date, base_slug)
        seen_slugs[key] = seen_slugs.get(key, 0) + 1
        slug = base_slug if seen_slugs[key] == 1 else f"{base_slug}-{seen_slugs[key]}"
        path = _entry_path(args.type, date, slug)
        # A same-derived-filename collision is only a genuine idempotent re-run if the EXISTING file's
        # content matches byte-for-byte what we're about to write -- never compare paths alone. If the
        # content differs, this is a real, different historical entry colliding on the same filename;
        # keep disambiguating with the same same-day-collision counter already used above, rather than
        # silently dropping it.
        while path.exists():
            with open(path, "r", newline="") as ef:
                existing = ef.read()
            if existing == chunk_text:
                skipped += 1
                break
            seen_slugs[key] += 1
            slug = f"{base_slug}-{seen_slugs[key]}"
            path = _entry_path(args.type, date, slug)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, "w", newline="") as wf:
                wf.write(chunk_text)
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

        # Checker round 4, bug 1: two DIFFERENT, both-valid task-ids that only differ in '_' vs '-'
        # must NOT collide on the same derived filename -- _slugify() collapses both to the same '-',
        # but a validated task-id must be used non-lossily instead.
        with open(bf, "w") as f:
            f.write("- body for task a_b\n")
        code, out = _run(["add", "--type", "flow", "--task", "a_b", "--date", "2026-03-01",
                           "--title", "a_b: underscore task", "--body-file", bf])
        assert code == 0, out
        with open(bf, "w") as f:
            f.write("- body for task a-b\n")
        code, out = _run(["add", "--type", "flow", "--task", "a-b", "--date", "2026-03-01",
                           "--title", "a-b: hyphen task", "--body-file", bf])
        assert code == 0, (
            f"a distinct task-id 'a-b' must not collide with the already-written 'a_b' entry: {out!r}")
        p_ab_us = _entry_path("flow", "2026-03-01", "a_b")
        p_ab_hy = _entry_path("flow", "2026-03-01", "a-b")
        assert p_ab_us.exists() and p_ab_hy.exists() and p_ab_us != p_ab_hy, (
            "'a_b' and 'a-b' must be written to two distinct files")
        assert "body for task a_b" in p_ab_us.read_text()
        assert "body for task a-b" in p_ab_hy.read_text()
        # each must be independently addressable via show, without the other's content leaking in
        code, out = _run(["show", "--type", "flow", "--task", "a_b"])
        assert code == 0 and "body for task a_b" in out and "body for task a-b" not in out, out
        code, out = _run(["show", "--type", "flow", "--task", "a-b"])
        assert code == 0 and "body for task a-b" in out and "body for task a_b" not in out, out
        # and via list
        code, out = _run(["list", "--type", "flow"])
        assert "a_b" in out and "a-b" in out, "both distinct task-ids must appear in the full listing"

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
        # a --type-scoped search must actually be SCOPED: the needle only exists in a decision-type
        # entry, so a --type flow search for it must return zero matches, and --type decision must find it.
        code, out = _run(["search", "UNIQUEMARKERXYZ", "--type", "flow"])
        assert code == 0 and out.strip() == "", (
            f"a --type flow search for a needle that only exists in a decision-type entry must return "
            f"zero matches: {out!r}")
        code, out = _run(["search", "UNIQUEMARKERXYZ", "--type", "decision"])
        assert code == 0 and "other-task" in out, (
            f"a --type decision search must find the needle in the decision-type entry containing it: {out!r}")
        code, out = _run(["search", "NOSUCHSTRINGATALL"])
        assert code == 0 and out.strip() == "", "a query with zero hits must print nothing to stdout"

        # Checker round 3, bug 2: an invalid --type must be rejected the same way every sibling
        # subcommand (add/show/list/migrate) already rejects it, not silently treated as "no matches".
        code, out = _run(["search", "UNIQUEMARKERXYZ", "--type", "not-audit-type"])
        assert code != 0, "search must reject an invalid --type, not silently report 'no matches'"
        # --type stays optional for search (defaults to both kinds) -- omitting it must still work.
        code, out = _run(["search", "UNIQUEMARKERXYZ"])
        assert code == 0 and "other-task" in out, "omitting --type must still search both kinds"

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

        # Checker round 1, bug 1: `show` must find a migrated legacy entry by SUBSTRING match against
        # its filename slug, not only an exact suffix match -- migrated entries are named after their
        # (slugified) TITLE, since they never had a discrete task-id.
        os.environ["SM_AUDIT_DIR"] = os.path.join(tmpdir, "audit4")
        mono3 = os.path.join(tmpdir, "mono3.md")
        with open(mono3, "w") as f:
            f.write(
                "# flow.md\n\n---\n## 2025-03-01 — harden-checker-invariant: fix the pane recipe quoting bug\n\n"
                "- did the fix\n"
            )
        code, out = _run(["migrate", "--type", "flow", "--file", mono3])
        assert code == 0 and "migrated 1 entries" in out, out
        code, out = _run(["show", "--type", "flow", "--task", "harden-checker-invariant"])
        assert code == 0 and "did the fix" in out, (
            f"show must find a migrated entry by substring match against its filename slug: {out!r}")
        # a broad substring matching more than one file must print EVERY match, never silently pick one
        mono4 = os.path.join(tmpdir, "mono4.md")
        with open(mono4, "w") as f:
            f.write(
                "# flow.md\n\n---\n## 2025-03-02 — harden-checker-invariant: a second unrelated entry\n\n"
                "- second body marker\n"
            )
        code, out = _run(["migrate", "--type", "flow", "--file", mono4])
        assert code == 0, out
        code, out = _run(["show", "--type", "flow", "--task", "harden-checker-invariant"])
        assert code == 0 and "did the fix" in out and "second body marker" in out, (
            f"show must print EVERY matching entry, not just one: {out!r}")

        # Checker round 1, bug 2: a bare '---' inside an entry's own body (an ordinary markdown
        # horizontal rule) must not be treated as an entry boundary -- only entry HEADERS split entries.
        os.environ["SM_AUDIT_DIR"] = os.path.join(tmpdir, "audit5")
        mono5 = os.path.join(tmpdir, "mono5.md")
        with open(mono5, "w") as f:
            f.write(
                "# flow.md\n\n---\n## 2025-04-01 — midrule-task: has a rule in its own body\n\n"
                "before-marker\n---\nafter-marker\n\n---\n## 2025-04-02 — next-task: y\n\nz\n"
            )
        code, out = _run(["migrate", "--type", "flow", "--file", mono5])
        assert code == 0 and "migrated 2 entries" in out, out
        p_mid = _entry_path("flow", "2025-04-01", "midrule-task-has-a-rule-in-its-own-body")
        assert p_mid.exists(), f"expected {p_mid}"
        mid_content = p_mid.read_text()
        assert "before-marker" in mid_content and "after-marker" in mid_content, (
            f"a bare '---' inside an entry's own body must not truncate the entry: {mid_content!r}")

        # Checker round 1, bug 3: a filename collision with a DIFFERENT existing file (not a genuine
        # idempotent re-run) must never silently drop the real source entry -- it must be written under
        # a disambiguating suffix instead, and the unrelated pre-existing file must stay untouched.
        os.environ["SM_AUDIT_DIR"] = os.path.join(tmpdir, "audit6")
        # the pre-existing file's path must be the EXACT slug the real entry below will also slugify to
        # (i.e. slugify("collide-task") == "collide-task") for this to actually exercise a collision.
        collision_path = _entry_path("flow", "2025-05-01", _slugify("collide-task"))
        collision_path.parent.mkdir(parents=True, exist_ok=True)
        collision_path.write_text(
            "## 2025-05-01 — collide-task: a totally unrelated pre-existing entry\n\nUNRELATED-CONTENT\n")
        mono6 = os.path.join(tmpdir, "mono6.md")
        with open(mono6, "w") as f:
            f.write(
                "# flow.md\n\n---\n## 2025-05-01 — collide-task\n\n"
                "MIGRATED-UNIQUE-MARKER\n"
            )
        code, out = _run(["migrate", "--type", "flow", "--file", mono6])
        assert code == 0 and "migrated 1 entries" in out, (
            f"a real, different colliding entry must be counted as migrated, not silently skipped: {out!r}")
        assert "UNRELATED-CONTENT" in collision_path.read_text(), (
            "the unrelated pre-existing file must never be overwritten")
        all_flow_text = "".join(fp.read_text() for fp in (_audit_dir() / "flow").glob("*.md"))
        assert "MIGRATED-UNIQUE-MARKER" in all_flow_text, (
            "a real source entry colliding on filename with different existing content must survive "
            "under a disambiguating suffix, never be silently dropped")

        # Checker round 1, bug 4: a CRLF-encoded source must migrate byte-verbatim, never silently
        # rewritten with LF-only line endings.
        os.environ["SM_AUDIT_DIR"] = os.path.join(tmpdir, "audit7")
        mono7 = os.path.join(tmpdir, "mono7.md")
        crlf_text = (
            "# flow.md\r\n\r\n---\r\n## 2025-06-01 — crlf-task: uses crlf line endings\r\n\r\n"
            "- detail one\r\n"
        )
        with open(mono7, "wb") as f:
            f.write(crlf_text.encode("utf-8"))
        code, out = _run(["migrate", "--type", "flow", "--file", mono7])
        assert code == 0 and "migrated 1 entries" in out, out
        p_crlf = _entry_path("flow", "2025-06-01", "crlf-task-uses-crlf-line-endings")
        assert p_crlf.exists(), f"expected {p_crlf}"
        raw = p_crlf.read_bytes()
        assert b"\r\n" in raw, (
            f"a CRLF-encoded source must be migrated byte-verbatim: {raw!r}")
        assert b"detail one" in raw

        # Checker round 1, bug 5: a single entry with an unusually long --title must not blow up
        # INDEX.md -- the entry-count cap alone does not bound an individual title's length. The full,
        # untruncated title must still live in the per-task file itself.
        os.environ["SM_AUDIT_DIR"] = os.path.join(tmpdir, "audit8")
        bf2 = os.path.join(tmpdir, "body2.txt")
        with open(bf2, "w") as f:
            f.write("- huge title regression\n")
        huge_title = "x" * 200000
        code, out = _run(["add", "--type", "flow", "--task", "huge-title-task", "--date", "2026-02-02",
                           "--title", huge_title, "--body-file", bf2])
        assert code == 0, out
        index_text2 = (_audit_dir() / "INDEX.md").read_text()
        assert len(index_text2) < 20000, (
            f"a single entry with an unusually long --title must not blow up INDEX.md -- got "
            f"{len(index_text2)} bytes")
        p_huge = _entry_path("flow", "2026-02-02", "huge-title-task")
        assert huge_title in p_huge.read_text(), "the full untruncated title must survive in the per-task file"
        assert huge_title not in index_text2, "INDEX.md must never render the full untruncated title"

        # Checker round 2, bug 1: a trailing '---' on the LAST entry (no next header follows it) is
        # that entry's own real body content, not a boundary separator, and must be preserved verbatim.
        os.environ["SM_AUDIT_DIR"] = os.path.join(tmpdir, "audit9")
        mono8 = os.path.join(tmpdir, "mono8.md")
        with open(mono8, "w") as f:
            f.write("# flow.md\n\n---\n## 2026-01-01 — final-rule\n\nmust-remain\n---\n")
        code, out = _run(["migrate", "--type", "flow", "--file", mono8])
        assert code == 0 and "migrated 1 entries" in out, out
        p_final = _entry_path("flow", "2026-01-01", "final-rule")
        assert p_final.exists(), f"expected {p_final}"
        final_content = p_final.read_text()
        assert final_content == "## 2026-01-01 — final-rule\n\nmust-remain\n---\n", (
            f"a trailing '---' on the LAST entry must be preserved verbatim, not stripped as if it were "
            f"a boundary separator: {final_content!r}")

        # Checker round 2, bug 2: migrate must never add a trailing newline the source didn't have --
        # that would grow the migrated file by one byte and break the byte-verbatim guarantee.
        os.environ["SM_AUDIT_DIR"] = os.path.join(tmpdir, "audit10")
        mono9 = os.path.join(tmpdir, "mono9.md")
        no_final_nl_entry = "## 2026-01-02 — no-final-newline\n\nbody-without-final-newline"
        with open(mono9, "w") as f:
            f.write("# flow.md\n\n---\n" + no_final_nl_entry)
        code, out = _run(["migrate", "--type", "flow", "--file", mono9])
        assert code == 0 and "migrated 1 entries" in out, out
        p_nonl = _entry_path("flow", "2026-01-02", "no-final-newline")
        assert p_nonl.exists(), f"expected {p_nonl}"
        raw_nonl = p_nonl.read_bytes()
        assert raw_nonl == no_final_nl_entry.encode("utf-8"), (
            f"migrate must never append a trailing newline the source's last entry didn't have: {raw_nonl!r}")

        # Checker round 2, bug 3: _truncate must never return MORE than max_len characters total,
        # ellipsis included -- it must reserve room for "..." within the cap, not append it on top.
        for n in (2, 3, 5, 50, _INDEX_TITLE_MAX):
            t = _truncate("x" * (n + 500), max_len=n)
            assert len(t) <= n, f"_truncate(max_len={n}) must return at most {n} chars, got {len(t)}: {t!r}"
        assert len(_truncate("x" * 121, max_len=120)) <= 120, (
            "_truncate(max_len=120) must never return more than 120 characters")

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
