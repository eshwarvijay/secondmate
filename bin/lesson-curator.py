#!/usr/bin/env python3
# ponytail: a read-only verdict report over evidence the lesson system already records; zero new state.
"""lesson-curator.py -- read-only curation-signal report over the lesson system's own evidence.

Usage: bin/lesson-curator.py --report
       bin/lesson-curator.py --selfcheck
       bin/lesson-curator.py --help

Prints one line per lesson file under the lessons dir (SM_LESSONS_DIR, default: bin/lessons/),
computing a retire-candidate | watch | keep verdict per lesson from two evidence sources the
lesson system already maintains: each lesson file's own helpful_count/harmful_count frontmatter
fields (feedback tags recorded by lesson-lookup.py's `tag --outcome` subcommand) and the shared
injection ledger at .secondmate/lesson-injections.jsonl (resolved via the same anchoring
lesson-lookup.py's _lesson_ledger_path() uses). A human owns every retire/rewrite decision --
this tool only proposes signal from recorded evidence; it never edits, deletes, retires, or
rewrites anything, and never acts on its own verdicts.

Read-only on real data: --report (and every path that touches real lesson files or the real
ledger) never writes, removes, or locks any real file, and takes no lock at all
(lesson-lookup.py's flock-based lock guards its `tag` WRITES; this tool has none). --selfcheck
is the one explicit, intentional exception: it builds and tears down its own throwaway fixture
lessons and ledger in an isolated temp directory purely to test itself.

Reuse, never reimplement: frontmatter parsing (parse_frontmatter), lesson loading (load_lessons),
count reading (_counts), and ledger-path anchoring (_lesson_ledger_path) all come from the real
bin/lesson-lookup.py, imported in-process below. If that import fails, this tool dies loudly --
it never falls back to a hand-rolled reimplementation. Run `--help` for the report format, the
verdict rules, and the exit-status contract.
"""
import sys
import os
import json
import pathlib
import importlib.util

EXIT_CANNOT_RUN = 1  # the single documented nonzero exit code, strictly "could not run at all"

# "tags" in the verdict rules means lesson-lookup.py's feedback-tag events (helpful_count + harmful_count, written by its `tag --outcome` subcommand), NOT the frontmatter's topical `tags:` YAML list -- a different, unrelated field with the same name.
FEEDBACK_TAGS_MEANING = ('verdict "total_tags" counts feedback-tag events (helpful_count + harmful_count '
                         'from lesson-lookup.py `tag --outcome`), never the frontmatter topical `tags:` list')

RETIRE_MIN_TOTAL_TAGS = 3        # retire rule 1: harmful > helpful AND total feedback tags >= 3
RETIRE_MIN_ROWS_NOT_NAMING = 10  # retire rule 2: zero injections AND >= 10 ledger rows not naming this lesson
WATCH_MIN_INJECTIONS = 3        # watch: zero feedback tags AND >= 3 injections

VERDICT_RETIRE = 'retire-candidate'
VERDICT_WATCH = 'watch'
VERDICT_KEEP = 'keep'

REPORT_HEADER = '\t'.join(['lesson_id', 'category', 'helpful', 'harmful', 'injections', 'verdict'])


def _warn(msg):
    print(f"WARNING: {msg}", file=sys.stderr)


def _fatal(msg):
    """The one route to the single documented nonzero exit code: this tool cannot run at all."""
    sys.stderr.write(f"lesson-curator.py: FATAL: {msg}\n")
    sys.exit(EXIT_CANNOT_RUN)


def _import_lesson_lookup():
    """Import the real bin/lesson-lookup.py in-process. On any failure, die loudly -- never fall
    back to a hand-rolled parser/loader/anchoring."""
    src = pathlib.Path(__file__).resolve().parent / 'lesson-lookup.py'
    sys.dont_write_bytecode = True  # an in-place import must not litter bin/__pycache__ with a .pyc
    spec = importlib.util.spec_from_file_location('lesson_lookup_for_curator', str(src))
    if spec is None or spec.loader is None:
        _fatal(f"could not set up an import of {src} -- refusing to run a reimplementation")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as e:
        _fatal(f"could not import {src}: {e!r} -- refusing to run a reimplementation")
    return module


_LL = _import_lesson_lookup()
# The reused, real implementations this report is built on (never reimplemented here):
parse_frontmatter = _LL.parse_frontmatter  # the real frontmatter parser
load_lessons = _LL.load_lessons            # the real lesson loader (the report's one parse pass)
_counts = _LL._counts                      # the real helpful_count/harmful_count reader


def _curator_lesson_id(filepath, lessons_dir):
    """Lesson id by the same scheme lesson-lookup.py's own ids use: path relative to the lessons
    dir, no extension, '/'-joined (e.g. "debugging/avoid-ad-hoc-debug-loops"). Written here rather
    than importing lesson-lookup.py's private _lesson_id(); the SCHEME is the contract, not the
    function, and this task pins this file's own copy of it."""
    try:
        rel = pathlib.Path(filepath).resolve().relative_to(pathlib.Path(lessons_dir).resolve())
        return rel.with_suffix('').as_posix()
    except (ValueError, OSError):
        return pathlib.Path(filepath).stem


def _read_ledger_rows(ledger_path):
    """Read the injection ledger (the caller resolves the path with the same _lesson_ledger_path()
    anchoring lesson-lookup.py writes through). Returns one list-of-strings per WELL-FORMED row
    (in file order). A missing file is the normal fresh state -> zero rows, no warning. A corrupt
    row (unparseable JSON, not an object, or a non-list lesson_ids) is excluded from ALL counts
    with a stderr warning -- a corrupt row must never drive a verdict in either direction.
    Ledger content is only ever compared as strings against real lesson ids; no filesystem path
    is ever constructed from it."""
    p = pathlib.Path(ledger_path)
    try:
        if not p.exists():
            return []
        text = p.read_text(encoding='utf-8', errors='replace')
    except OSError as e:
        _warn(f"could not read injection ledger {p} ({e}) -- treating it as empty; injection counts below are incomplete")
        return []
    rows = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            _warn(f"{p}:{lineno}: not valid JSON -- row excluded from all counts")
            continue
        if not isinstance(rec, dict):
            _warn(f"{p}:{lineno}: not a JSON object -- row excluded from all counts")
            continue
        ids = rec.get('lesson_ids')
        if not isinstance(ids, list):
            _warn(f"{p}:{lineno}: missing or non-list lesson_ids -- row excluded from all counts")
            continue
        rows.append([i for i in ids if isinstance(i, str)])
    return rows


def _verdict(helpful, harmful, injections, rows_not_naming):
    """The verdict rules, at their exact boundaries. 'tags' means FEEDBACK_TAGS_MEANING (see the
    pinned constant above): feedback-tag counts, never the topical tags: list."""
    total_tags = helpful + harmful
    if (harmful > helpful and total_tags >= RETIRE_MIN_TOTAL_TAGS) or \
       (injections == 0 and rows_not_naming >= RETIRE_MIN_ROWS_NOT_NAMING):
        return VERDICT_RETIRE
    if total_tags == 0 and injections >= WATCH_MIN_INJECTIONS:
        return VERDICT_WATCH
    return VERDICT_KEEP


def _explain_skipped(md_path):
    """load_lessons() skips an unparseable/unreadable file after printing its own one-line warning;
    this re-checks that file with the REAL imported parser so this tool's warning says which of
    the two it was. Diagnostic only -- nothing is written; the file's counts degrade to 0/0."""
    try:
        content = pathlib.Path(md_path).read_text(encoding='utf-8', errors='replace')
    except OSError as e:
        return f"unreadable ({e})"
    fm, _body = parse_frontmatter(content)
    if fm is None:
        return "unparseable frontmatter"
    return "skipped by load_lessons but parses on re-read"


def collect_curation(lessons_dir, ledger_path):
    """The one real data pass: --report's own line-building and the selfcheck's assertions both go
    through this function, so the selfcheck can never be a reimplementation of the logic under
    test. Returns a list of entries (sorted by lesson id), one per *.md file under lessons_dir --
    including files whose frontmatter is unparseable (counted 0/0, with a stderr warning).
    Emits stderr warnings for unparseable frontmatter and orphaned ledger references. Raises
    OSError if the lessons directory can't be listed (callers map that to EXIT_CANNOT_RUN)."""
    lessons_path = pathlib.Path(lessons_dir)
    if not lessons_path.is_dir():
        raise FileNotFoundError(f"lessons directory not found: {lessons_dir}")
    # Only real FILES are lessons: a filesystem entry that merely matches '*.md' by name -- e.g. a
    # directory called "not-a-lesson.md" -- must never become a report row (it would read 0/0/0
    # and, on a ledger with >= 10 rows, flip to a false retire-candidate). The reused
    # load_lessons() independently skips unreadable entries with its own read-failure warning;
    # this is_file() filter is the report-side guarantee, at the one place this file discovers
    # lesson entries (every other path -- the loader, the diagnoser -- only ever sees entries
    # that came through here or already skip unreadable ones themselves).
    md_files = sorted(p for p in lessons_path.rglob('*.md') if p.is_file())

    # The one parse pass: the real loader. It warns on (and skips) unparseable/unreadable files;
    # the loop below detects those via its own listing and adds this tool's precise warning.
    parsed = {}
    for filepath, fm, _body in load_lessons(lessons_dir):
        parsed[str(filepath)] = fm

    ledger_rows = _read_ledger_rows(ledger_path)
    total_rows = len(ledger_rows)
    # set(): a row naming an id twice still names it once -- rows are counted per lesson, so one
    # row naming TWO lessons adds 1 to each lesson's own count, never more (no inflation).
    row_count_by_id = {}
    for ids in ledger_rows:
        for lid in set(ids):
            row_count_by_id[lid] = row_count_by_id.get(lid, 0) + 1

    entries = []
    real_ids = set()
    for md in md_files:
        lesson_id = _curator_lesson_id(md, lessons_dir)
        real_ids.add(lesson_id)
        fm = parsed.get(str(md))
        if fm is None:
            _warn(f"{md}: {_explain_skipped(md)} -- reported with helpful=0 harmful=0")
        helpful, harmful = _counts(fm) if fm is not None else (0, 0)
        injections = row_count_by_id.get(lesson_id, 0)
        # A row that names this lesson counts toward injections, so it must NOT count toward
        # "rows that don't name it": the tally is total well-formed rows minus rows naming it.
        rows_not_naming = total_rows - injections
        entries.append({
            'id': lesson_id,
            'category': lesson_id.split('/')[0],
            'helpful': helpful,
            'harmful': harmful,
            'injections': injections,
            'rows_not_naming': rows_not_naming,
            'verdict': _verdict(helpful, harmful, injections, rows_not_naming),
        })
    entries.sort(key=lambda e: e['id'])

    # Orphaned ledger references: a row names a lesson id with no matching lesson file. Pure
    # string comparison against the real ids -- never a filesystem path built from ledger content.
    # The row is an orphan for THAT id's own counts only; it still counts toward every real
    # lesson's "rows that don't name it" tally (already reflected in total_rows above).
    for lid, count in sorted(row_count_by_id.items()):
        if lid not in real_ids:
            _warn(f"orphaned ledger reference: lesson id {lid!r} named in {count} ledger row(s) but no "
                  f"lesson file matches -- those rows still count toward other lessons' not-naming tallies")
    return entries


def cmd_report():
    lessons_dir = _LL._lessons_dir()
    ledger_path = _LL._lesson_ledger_path()
    try:
        entries = collect_curation(lessons_dir, ledger_path)
    except OSError as e:
        _fatal(f"cannot run at all: {e}")
    print(REPORT_HEADER)
    for e in entries:
        print('\t'.join([e['id'], e['category'], str(e['helpful']), str(e['harmful']),
                         str(e['injections']), e['verdict']]))
    return 0


HELP_TEXT = f"""lesson-curator.py -- read-only curation-signal report over the lesson system's own evidence.

Usage:
  bin/lesson-curator.py --report      print the report (one line per lesson file)
  bin/lesson-curator.py --selfcheck   run this tool's own fixture-based assertions
  bin/lesson-curator.py --help        print this help

A HUMAN OWNS EVERY RETIRE/REWRITE DECISION. This tool only proposes signal from recorded
evidence; it never edits, deletes, retires, or rewrites any lesson, and it never acts on its
own verdicts. --report (and every path that touches real lesson files or the real ledger)
never writes, removes, or locks any real file: it takes no lock at all (lesson-lookup.py's
flock-based lock guards its `tag` writes -- there are none here). The one explicit,
intentional exception is --selfcheck: it creates and cleans up its own throwaway fixture
lessons and ledger in an isolated temp directory purely to test itself -- it never touches
the real lesson store or the real ledger.

--report prints a tab-separated table to stdout, one line per *.md file under the lessons
directory (SM_LESSONS_DIR, default: bin/lessons/), sorted by lesson id, preceded by a header:

  lesson_id<TAB>category<TAB>helpful<TAB>harmful<TAB>injections<TAB>verdict

  lesson_id        path relative to the lessons dir, no extension
                   (e.g. "debugging/avoid-ad-hoc-debug-loops")
  category        first path segment of the id (e.g. "debugging")
  helpful/harmful  the file's own helpful_count/harmful_count frontmatter fields
  injections      how many ledger rows name this lesson id (exact id match)
  verdict         one of: retire-candidate | watch | keep

Verdict rules (every >= is an exact boundary; one below it does NOT fire):
  retire-candidate  (harmful > helpful AND total_tags >= 3) OR
                    (zero injections AND >= 10 ledger rows that do NOT name this lesson id)
  watch             total_tags == 0 AND injections >= 3
  keep              otherwise (default)

"total_tags" means {FEEDBACK_TAGS_MEANING}.

Evidence sources (all reused from the real lesson system, never reimplemented here):
  - lesson frontmatter, parsed by the real bin/lesson-lookup.py imported in-process
    (parse_frontmatter / load_lessons / _counts); if that import fails, this tool dies
    loudly rather than falling back to a hand-rolled parser.
  - the injection ledger, resolved by the same anchoring lesson-lookup.py's own
    _lesson_ledger_path() uses: SM_LESSON_LEDGER, else SM_LOOP_STATE/lesson-injections.jsonl,
    else the git-common-dir-anchored .secondmate/lesson-injections.jsonl shared across
    worktrees. A missing ledger file is the normal fresh state (zero rows, no warning).
    A corrupt ledger row (unparseable JSON, not an object, or a non-list lesson_ids) is
    excluded from ALL counts with a warning -- a corrupt row never drives a verdict.

stderr carries warnings only: unparseable lesson frontmatter (the file still gets a report
line, counted 0/0), orphaned ledger references (a row names a lesson id with no matching
lesson file; those rows still count toward other lessons' not-naming tallies), and corrupt
ledger rows (see above). stdout carries only the report.

Exit status: 0 for every successful run of --report / --selfcheck / --help, whatever verdicts
were computed. {EXIT_CANNOT_RUN} is the single documented nonzero exit code, used strictly for
"could not run at all": unrecognized arguments, bin/lesson-lookup.py cannot be imported, or
the lessons directory does not exist / cannot be listed.
"""


def selfcheck():
    """Fixture-based assertions over the REAL report/verdict code paths -- main(['--report']),
    collect_curation, and _verdict -- never a reimplementation of the logic under test. Builds
    real lesson .md files and a real ledger in temp dirs, injects them through the same env
    overrides lesson-lookup.py uses (SM_LESSONS_DIR / SM_LESSON_LEDGER), and asserts exact
    verdict strings at the real rule boundaries: total_tags at exactly 3 and 2, injections at
    exactly 3 and 2, not-naming rows at exactly 10 and 9, plus the discriminating fixture that
    proves the feedback-tag-count reading of "tags" wins over the topical tags: list, and the
    multi-lesson-row ledger arithmetic."""
    import io
    import tempfile
    import shutil
    from contextlib import redirect_stdout, redirect_stderr

    saved_env = {k: os.environ.get(k) for k in ('SM_LESSONS_DIR', 'SM_LESSON_LEDGER')}
    tmpdirs = []

    def _scenario():
        """A fresh fixture lessons dir + fixture ledger path, injected via the real env overrides."""
        lessons = pathlib.Path(tempfile.mkdtemp(prefix='curator-selfcheck-'))
        tmpdirs.append(lessons)
        ledger = lessons / 'lesson-injections.jsonl'
        os.environ['SM_LESSONS_DIR'] = str(lessons)
        os.environ['SM_LESSON_LEDGER'] = str(ledger)
        return lessons, ledger

    def _lesson(lessons_dir, lesson_id, helpful=None, harmful=None, topical_tags=1, raw=None):
        """Write a real lesson .md file with the same frontmatter shape lesson-lookup.py parses.
        helpful/harmful=None writes NO count field (a never-tagged lesson). topical_tags=N writes
        N entries in the topical tags: list -- the field that must NOT be read as feedback tags."""
        path = pathlib.Path(lessons_dir) / (lesson_id + '.md')
        path.parent.mkdir(parents=True, exist_ok=True)
        if raw is not None:
            path.write_text(raw)
            return
        lines = ['---', 'tags:']
        lines += [f'  - topical{i}' for i in range(topical_tags)]
        lines += ['evidence: E0', 'earned-in: curator-selfcheck']
        if helpful is not None:
            lines.append(f'helpful_count: {helpful}')
        if harmful is not None:
            lines.append(f'harmful_count: {harmful}')
        lines += ['---', '', f'Fixture body for {lesson_id}.']
        path.write_text('\n'.join(lines) + '\n')

    def _ledger(ledger_path, rows, extra_lines=()):
        """Write a fixture ledger: one real-shaped row (ts/task_id/lesson_ids) per list of ids,
        plus optional raw extra lines (corrupt-row fixtures)."""
        lines = [json.dumps({'ts': '2026-10-13T00:00:00', 'task_id': f'scenario-{i}', 'lesson_ids': list(ids)})
                 for i, ids in enumerate(rows)]
        lines += list(extra_lines)
        pathlib.Path(ledger_path).write_text('\n'.join(lines) + ('\n' if lines else ''))

    def _run_report():
        """End-to-end run of the REAL report code path against the current env-injected fixtures."""
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = main(['--report'])
        return rc, out.getvalue(), err.getvalue()

    def _rows(stdout):
        """Parse the real report output into {lesson_id: {category, helpful, harmful, injections,
        verdict}} -- asserting the exact header and the exact 6-field line format on the way."""
        lines = stdout.splitlines()
        assert lines and lines[0] == REPORT_HEADER, f"report must start with the exact header:\n{stdout}"
        rows = {}
        for line in lines[1:]:
            fields = line.split('\t')
            assert len(fields) == 6, f"report line must have exactly 6 tab-separated fields: {line!r}"
            assert fields[0] not in rows, f"duplicate report line for {fields[0]!r}"
            rows[fields[0]] = {'category': fields[1], 'helpful': fields[2], 'harmful': fields[3],
                               'injections': fields[4], 'verdict': fields[5]}
        return rows

    def _entries():
        """The real internal data pass (the same collect_curation --report itself calls). Its
        stderr warnings were already captured and asserted by the scenario's end-to-end run --
        suppress the duplicates here so the selfcheck's own output stays clean."""
        with redirect_stderr(io.StringIO()):
            return {e['id']: e for e in collect_curation(_LL._lessons_dir(), _LL._lesson_ledger_path())}

    def _assert_row(rows, lesson_id, verdict, helpful, harmful, injections):
        assert rows[lesson_id]['verdict'] == verdict, (
            f"{lesson_id}: expected verdict {verdict!r}, got {rows[lesson_id]['verdict']!r} -- full rows: {rows}")
        assert rows[lesson_id]['helpful'] == helpful and rows[lesson_id]['harmful'] == harmful and \
            rows[lesson_id]['injections'] == injections, f"{lesson_id}: wrong counts: {rows[lesson_id]}"

    try:
        # --- --help contract ---------------------------------------------------------------
        out = io.StringIO()
        with redirect_stdout(out):
            rc = main(['--help'])
        assert rc == 0, "--help must exit 0"
        help_text = out.getvalue()
        assert 'A HUMAN OWNS EVERY RETIRE/REWRITE DECISION' in help_text and 'never acts on' in help_text, \
            "--help must state that a human owns every retire/rewrite decision"
        assert FEEDBACK_TAGS_MEANING in help_text, "--help must state the pinned 'tags' interpretation"
        assert str(EXIT_CANNOT_RUN) in help_text, "--help must document the single nonzero exit code"
        # The scoped zero-write guarantee must be in the PRINTED --help text, and the old blanket
        # wording must not come back: a future edit that silently reverts HELP_TEXT to the
        # unqualified "writes no file at all" claim must fail --selfcheck, not just a manual read.
        assert 'never writes, removes, or locks any real file' in help_text \
            and 'intentional exception is --selfcheck' in help_text, \
            "--help must scope its zero-write guarantee to real data and name --selfcheck's fixture exception"
        assert 'writes no file at all' not in help_text, \
            "--help must not carry the old unqualified zero-write claim"

        # --- unrecognized arguments: the one documented nonzero exit code -------------------
        for bad_argv in ([], ['--bogus'], ['--report', '--selfcheck']):
            err = io.StringIO()
            with redirect_stderr(err):
                try:
                    main(bad_argv)
                    assert False, f"main({bad_argv!r}) must not succeed"
                except SystemExit as e:
                    assert e.code == EXIT_CANNOT_RUN, (
                        f"main({bad_argv!r}) must exit {EXIT_CANNOT_RUN}, got {e.code!r}")

        # --- a nonexistent lessons directory is "cannot run at all": the REAL --report entry
        #     point must exit with the single documented nonzero code -- pinned here so a
        #     regression in this exit-status contract fails --selfcheck, not just a manual check.
        #     Injected via SM_LESSONS_DIR, the same env override lesson-lookup.py itself reads.
        missing_base = pathlib.Path(tempfile.mkdtemp(prefix='curator-missing-'))
        tmpdirs.append(missing_base)
        os.environ['SM_LESSONS_DIR'] = str(missing_base / 'no-such-lessons-dir')
        os.environ['SM_LESSON_LEDGER'] = str(missing_base / 'no-such-ledger.jsonl')
        err = io.StringIO()
        with redirect_stderr(err):
            try:
                main(['--report'])
                assert False, "--report against a nonexistent lessons dir must not succeed"
            except SystemExit as e:
                assert e.code == EXIT_CANNOT_RUN, (
                    f"a nonexistent lessons dir must exit the documented code {EXIT_CANNOT_RUN}, got {e.code!r}")
        assert 'FATAL' in err.getvalue(), (
            f"the nonzero exit must come from the documented fatal path:\n{err.getvalue()}")

        # --- direct boundary assertions on the REAL verdict function -----------------------
        # retire rule 1: total feedback tags at exactly 3 fires, at 2 does not
        assert _verdict(1, 2, 1, 1) == VERDICT_RETIRE, "harmful>helpful AND total_tags==3 exactly -> retire-candidate"
        assert _verdict(0, 2, 1, 1) == VERDICT_KEEP, "harmful>helpful but total_tags==2 (below 3) -> keep"
        # watch: injections at exactly 3 fires, at 2 does not
        assert _verdict(0, 0, 3, 0) == VERDICT_WATCH, "total_tags==0 AND injections==3 exactly -> watch"
        assert _verdict(0, 0, 2, 0) == VERDICT_KEEP, "total_tags==0 AND injections==2 (below 3) -> keep"
        # retire rule 2: not-naming rows at exactly 10 fires, at 9 does not
        assert _verdict(0, 0, 0, 10) == VERDICT_RETIRE, "zero injections AND 10 rows not naming it exactly -> retire-candidate"
        assert _verdict(0, 0, 0, 9) == VERDICT_KEEP, "zero injections AND 9 rows (below 10) -> keep"

        # --- Scenario A: retire rule 1 boundary + "tags" means feedback counts, not the topical
        #     tags: list (retire direction). exact-three has ONE topical tag but 3 feedback tags
        #     -> retire; below-three has FIFTEEN topical tags but only 2 feedback tags -> keep.
        lessons, ledger = _scenario()
        _lesson(lessons, 'retire/exact-three', helpful=1, harmful=2, topical_tags=1)
        _lesson(lessons, 'retire/below-three', helpful=0, harmful=2, topical_tags=15)
        _ledger(ledger, [['retire/exact-three'], ['retire/below-three']])
        rc, out, err = _run_report()
        assert rc == 0, f"--report must exit 0 (got {rc}); stderr: {err}"
        rows = _rows(out)
        _assert_row(rows, 'retire/exact-three', 'retire-candidate', '1', '2', '1')
        _assert_row(rows, 'retire/below-three', 'keep', '0', '2', '1')

        # --- Scenario B: watch boundary + "tags" means feedback counts (watch direction).
        #     exact-injections has NO count fields at all (so total feedback tags is 0) but a
        #     15-entry topical tags: list -- only the feedback reading can yield 'watch'.
        lessons, ledger = _scenario()
        _lesson(lessons, 'watch/exact-injections', topical_tags=15)
        _lesson(lessons, 'watch/below-injections', topical_tags=1)
        _ledger(ledger, [['watch/exact-injections']] * 3 + [['watch/below-injections']] * 2)
        rc, out, err = _run_report()
        assert rc == 0, f"--report must exit 0 (got {rc}); stderr: {err}"
        rows = _rows(out)
        _assert_row(rows, 'watch/exact-injections', 'watch', '0', '0', '3')
        _assert_row(rows, 'watch/below-injections', 'keep', '0', '0', '2')

        # --- Scenario C: multi-lesson-row arithmetic + orphaned ledger rows. 10 rows each name
        #     BOTH multi/a and multi/b (each lesson must count each row once -- 10, not 20), one
        #     orphan row names ghost/no-such-lesson (no file -- warned on stderr, never a report
        #     line, but still counts toward every real lesson's not-naming tally).
        lessons, ledger = _scenario()
        _lesson(lessons, 'multi/a', helpful=2, harmful=1)
        _lesson(lessons, 'multi/b')
        _lesson(lessons, 'zero/never-injected')
        _ledger(ledger, [['multi/a', 'multi/b']] * 10 + [['ghost/no-such-lesson']])
        rc, out, err = _run_report()
        assert rc == 0, f"--report must exit 0 (got {rc}); stderr: {err}"
        rows = _rows(out)
        _assert_row(rows, 'multi/a', 'keep', '2', '1', '10')    # harmful(1) < helpful(2): rule 1 off
        _assert_row(rows, 'multi/b', 'watch', '0', '0', '10')    # zero feedback tags, 10 injections
        _assert_row(rows, 'zero/never-injected', 'retire-candidate', '0', '0', '0')  # 11 rows not naming it
        assert 'ghost/no-such-lesson' not in rows, "an orphaned id must never become a report line"
        assert 'ghost/no-such-lesson' in err, "an orphaned ledger reference must be warned about on stderr"
        entries = _entries()
        # A row naming multi/a must NOT count toward multi/a's own "rows that don't name it" tally
        # (its only such row is the orphan row); the orphan row itself MUST count:
        assert entries['multi/a']['rows_not_naming'] == 1, entries['multi/a']
        assert entries['multi/b']['rows_not_naming'] == 1, entries['multi/b']
        assert entries['zero/never-injected']['rows_not_naming'] == 11, entries['zero/never-injected']

        # --- Scenario D: retire rule 2's 10-row boundary, exactly 10 vs one below (9). Same
        #     lessons, two ledgers: the only difference is one row.
        lessons, ledger = _scenario()
        _lesson(lessons, 'loner/never-injected')
        _lesson(lessons, 'loner/never-injected-nine')
        _lesson(lessons, 'busy/beaver', helpful=1, harmful=0)
        _ledger(ledger, [['busy/beaver']] * 10)
        rc, out, err = _run_report()
        assert rc == 0, f"--report must exit 0 (got {rc}); stderr: {err}"
        rows = _rows(out)
        _assert_row(rows, 'loner/never-injected', 'retire-candidate', '0', '0', '0')  # exactly 10 rows not naming it
        _assert_row(rows, 'loner/never-injected-nine', 'retire-candidate', '0', '0', '0')
        _assert_row(rows, 'busy/beaver', 'keep', '1', '0', '10')
        _ledger(ledger, [['busy/beaver']] * 9)
        rc, out, err = _run_report()
        assert rc == 0, f"--report must exit 0 (got {rc}); stderr: {err}"
        rows = _rows(out)
        _assert_row(rows, 'loner/never-injected', 'keep', '0', '0', '0')   # 9 rows (below 10) -> keep
        _assert_row(rows, 'loner/never-injected-nine', 'keep', '0', '0', '0')
        _assert_row(rows, 'busy/beaver', 'keep', '1', '0', '9')

        # --- Scenario E: a two-lesson row must not inflate either lesson's count past its real
        #     appearances -- here 2 rows naming both lessons means injections==2 (below watch's
        #     3), not 4: verdict must be keep, not watch.
        lessons, ledger = _scenario()
        _lesson(lessons, 'multi/x')
        _lesson(lessons, 'multi/y')
        _ledger(ledger, [['multi/x', 'multi/y']] * 2)
        rc, out, err = _run_report()
        assert rc == 0, f"--report must exit 0 (got {rc}); stderr: {err}"
        rows = _rows(out)
        _assert_row(rows, 'multi/x', 'keep', '0', '0', '2')
        _assert_row(rows, 'multi/y', 'keep', '0', '0', '2')

        # --- Scenario F: unparseable frontmatter still gets a report line (0/0 + warning), and
        #     corrupt ledger rows are excluded from ALL counts (9 well-formed rows exist; if the
        #     3 corrupt lines counted toward not-naming tallies, nine-good-rows would read 12
        #     and flip to retire-candidate).
        lessons, ledger = _scenario()
        _lesson(lessons, 'good/healthy', helpful=2, harmful=0)
        _lesson(lessons, 'edge/nine-good-rows')
        _lesson(lessons, 'broken/no-frontmatter',
                raw='This file has no frontmatter markers at all.\n')
        _ledger(ledger, [['good/healthy']] * 9, extra_lines=[
            'this is not json {{{',
            json.dumps({'task_id': 'bad-shape', 'lesson_ids': 'good/healthy'}),   # lesson_ids not a list
            json.dumps(['good/healthy']),                                        # valid JSON, not an object
        ])
        rc, out, err = _run_report()
        assert rc == 0, f"--report must exit 0 (got {rc}); stderr: {err}"
        rows = _rows(out)
        _assert_row(rows, 'good/healthy', 'keep', '2', '0', '9')
        _assert_row(rows, 'edge/nine-good-rows', 'keep', '0', '0', '0')
        _assert_row(rows, 'broken/no-frontmatter', 'keep', '0', '0', '0')  # one line per lesson FILE, even unparseable
        assert 'no-frontmatter' in err, "unparseable frontmatter must be warned about on stderr"
        assert err.count('excluded from all counts') == 3, f"expected 3 corrupt-row warnings:\n{err}"

        # --- Scenario G: a missing ledger file is the normal fresh state -- zero rows, no warning.
        lessons, ledger = _scenario()  # the ledger path is never written
        _lesson(lessons, 'fresh/never-looked-up', helpful=1, harmful=0)
        rc, out, err = _run_report()
        assert rc == 0, f"--report must exit 0 (got {rc}); stderr: {err}"
        rows = _rows(out)
        _assert_row(rows, 'fresh/never-looked-up', 'keep', '1', '0', '0')
        assert err == '', f"a missing ledger is the fresh state, not a warning:\n{err}"

        # --- Scenario H: a filesystem entry that is a DIRECTORY whose name ends in ".md" is not a
        #     lesson -- it must produce NO report row at all (an unfiltered name-match walk would
        #     read it as 0/0/0 and, with >= 10 ledger rows, flip it to a false retire-candidate).
        lessons, ledger = _scenario()
        _lesson(lessons, 'real/lesson', helpful=1, harmful=0)
        (pathlib.Path(lessons) / 'sneaky' / 'not-a-lesson.md').mkdir(parents=True)  # a DIRECTORY
        _ledger(ledger, [['real/lesson']])
        rc, out, err = _run_report()
        assert rc == 0, f"--report must exit 0 (got {rc}); stderr: {err}"
        rows = _rows(out)
        assert 'sneaky/not-a-lesson' not in rows and len(rows) == 1, (
            f"a directory named like a lesson must produce NO report row "
            f"(not even a 0/0/0 one): {rows}")
        _assert_row(rows, 'real/lesson', 'keep', '1', '0', '1')

        print("ok")
        return 0
    finally:
        for k, v in saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        for d in tmpdirs:
            shutil.rmtree(d, ignore_errors=True)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    allowed = ('--report', '--selfcheck', '--help', '-h')
    if not argv or any(a not in allowed for a in argv) or \
            ('--report' in argv and '--selfcheck' in argv):
        _fatal("unrecognized arguments: " + ' '.join(argv) +
               "\nusage: lesson-curator.py --report | --selfcheck | --help")
    if '--help' in argv or '-h' in argv:
        print(HELP_TEXT, end='')
        return 0
    if '--selfcheck' in argv:
        return selfcheck()
    return cmd_report()


if __name__ == '__main__':
    sys.exit(main())
