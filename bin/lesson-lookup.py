#!/usr/bin/env python3
# ponytail: store known failure patterns as retrievable lessons.
"""lesson-lookup.py -- retrieve known failure patterns from the lesson store.

Usage: bin/lesson-lookup.py --task "<description>" [--task-id <id>]
       bin/lesson-lookup.py tag --lesson-id <id> --outcome helpful|harmful
       bin/lesson-lookup.py selfcheck

Reads all bin/lessons/**/*.md files, parses frontmatter (stdlib only, no yaml),
scores non-E4 lessons by term overlap with the task description, and returns
a block with all E4 lessons (always) plus top-scoring non-E4 lessons up to a
reasonable cap (5-6 total). If the lesson store is unavailable, falls back to
the original 4 seed lessons' exact text.

Output format (byte-for-byte exact match on the header): '## Known failure
patterns — DO NOT SKIP' followed by one '- <lesson body>' bullet per selected
lesson, in deterministic order, each with a '(helpful X/Y)' success-rate
suffix when that lesson has any recorded helpful/harmful tags.

--task-id (distinct from the free-text --task used for relevance scoring) is
optional. When given (and it matches the same [A-Za-z0-9_-]{1,128} charset
claim-ledger.py already uses), the ids of the lessons actually selected for
this call are appended to an injection ledger -- see _lesson_ledger_path()
for its anchoring. This logging is entirely best-effort and fail-open: a
logging failure of any kind must never prevent a lesson from being printed
and injected into the caller's prompt, which is the one thing this script
must never fail to do.

`tag` records supervisor-observed feedback on one lesson (helpful/harmful),
incrementing that lesson file's own `helpful_count`/`harmful_count`
frontmatter fields via a surgical, atomic text edit (never a full YAML
round-trip) so every other line in the file -- tags, evidence, earned-in,
the body -- is preserved byte-for-byte. This is supervisor judgment recorded
after the fact, never an automated correlation against any other history.
"""
import sys
import os
import re
import json
import time
import pathlib
import tempfile
import subprocess
import contextlib
try:
    import fcntl
except ImportError:  # non-Unix (e.g. Windows) -> best-effort, no locking
    fcntl = None

# task-id charset/length discipline mirrors claim-ledger.py's _TASK_ID_RE exactly -- this is a purely
# advisory logging key, not a path component, but the same discipline still applies per this repo's
# shared-constraints convention.
_SCRIPT_PATH = os.path.abspath(__file__)

_TASK_ID_RE = re.compile(r'\A[A-Za-z0-9_-]{1,128}\Z')

# lesson-id is a '/'-joined relative path (no extension) under lessons_dir, e.g. "workflow/commit-before-done".
# Each '/'-separated segment is restricted to the same charset as a task-id, and no segment may be
# empty/'.'/'..' -- this is used to resolve a real file path (the `tag` subcommand), so it gets the
# same path-traversal-safe validation discipline as claim-ledger.py's task-id, generalized for '/'.
_LESSON_ID_RE = re.compile(r'\A[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\Z')


def _split_frontmatter(content):
    """Split '---\\nFRONTMATTER\\n---\\nBODY' into (raw_frontmatter_text, body), or (None, None) if
    malformed. Kept separate from parse_frontmatter() so the `tag` subcommand can edit the frontmatter
    as raw text (surgical line replace/append) without a full YAML round-trip serializer, which would
    risk reformatting or silently dropping fields this script never parses into its own dict."""
    if not content.startswith('---\n'):
        return None, None
    end_marker = content.find('\n---\n', 3)
    if end_marker == -1:
        return None, None
    return content[4:end_marker], content[end_marker + 5:]  # skip '\n---\n' and leading newline in body


def parse_frontmatter(content):
    """Parse YAML-shaped frontmatter between --- markers. Returns (frontmatter_dict, body) or (None, None) if malformed."""
    frontmatter_text, body = _split_frontmatter(content)
    if frontmatter_text is None:
        return None, None

    fm = {}
    lines = frontmatter_text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line or ':' not in line:
            i += 1
            continue
        key, _, value = line.partition(':')
        key = key.strip()
        value = value.strip()

        if key == 'tags':
            # Check if this is a multi-line YAML list (value is empty, next lines are '- item')
            if not value:
                tags = []
                i += 1
                # Collect subsequent indented dash-prefixed lines
                while i < len(lines):
                    tag_line = lines[i]
                    stripped = tag_line.strip()
                    # Match '  - <tag>' or '- <tag>' patterns
                    if stripped.startswith('- '):
                        tag_value = stripped[2:].strip()
                        if tag_value:
                            tags.append(tag_value)
                        i += 1
                    elif stripped == '':
                        i += 1
                    else:
                        # Not a tag line, stop collecting
                        break
                fm['tags'] = tags
                # Don't do i += 1 at the end of outer loop - already done in inner
                continue
            else:
                # Handle comma-separated or bracketed list
                value = value.strip('[]').strip()
                if value.startswith('"') or value.startswith("'"):
                    # Quoted list - simple parse
                    tags = re.findall(r'["\']([^"\']+)["\']', value)
                else:
                    tags = [t.strip() for t in value.split(',') if t.strip()]
            fm['tags'] = tags
        elif key == 'evidence':
            fm['evidence'] = value.upper()
        elif key == 'earned-in':
            fm['earned-in'] = value
        else:
            # Simple string value
            fm[key] = value
        i += 1

    return fm, body


def tokenize(text):
    """Tokenize text into words, lowercased, non-alphanumeric split."""
    if not text:
        return set()
    # Split on non-alphanumeric, lowercase
    tokens = re.split(r'[^a-z0-9]+', text.lower())
    return {t for t in tokens if t}


def score_lesson(lesson_body, tags, task_text):
    """Score a lesson against task text by term overlap."""
    task_tokens = tokenize(task_text)
    body_tokens = tokenize(lesson_body)
    tag_tokens = set()
    for tag in tags or []:
        tag_tokens.update(tokenize(tag))

    combined = body_tokens | tag_tokens
    if not combined:
        return 0

    overlap = task_tokens & combined
    return len(overlap)


def _counts(fm):
    """Read helpful_count/harmful_count out of a parsed frontmatter dict -- both are plain strings
    from parse_frontmatter's generic fallback branch (it has no int type), and either field may be
    absent entirely on a lesson file that predates them. Never raises: any garbage value degrades to 0."""
    def _to_int(v):
        try:
            return max(0, int(str(v).strip()))
        except (TypeError, ValueError):
            return 0
    return _to_int(fm.get('helpful_count', 0)), _to_int(fm.get('harmful_count', 0))


def load_lessons(lessons_dir):
    """Load all lesson files from the directory. Returns list of (filepath, frontmatter, body)."""
    lessons = []
    lessons_path = pathlib.Path(lessons_dir)

    if not lessons_path.exists():
        return lessons

    for md_file in lessons_path.rglob('*.md'):
        try:
            content = md_file.read_text(encoding='utf-8', errors='replace')
            fm, body = parse_frontmatter(content)
            if fm is None:
                print(f"WARNING: skipping malformed frontmatter in {md_file}", file=sys.stderr)
                continue
            lessons.append((md_file, fm, body))
        except Exception as e:
            print(f"WARNING: error reading {md_file}: {e}", file=sys.stderr)
            continue

    return lessons


def select_lessons(lessons, task_text, cap=6):
    """Select lessons: all E4 + top non-E4 up to cap. Returns list of (filepath, frontmatter, body).

    Non-E4 lessons are bucketed before being scored: a lesson that has NEVER been marked helpful
    (helpful_count == 0, regardless of harmful_count) is deprioritized as a whole bucket relative to
    ones that have -- proven feedback outranks raw relevance score, but relevance still governs
    ordering WITHIN each bucket. This never excludes a lesson outright; it only affects ordering (and,
    once the cap is reached, which non-E4 lessons make the cut). E4 lessons are unaffected -- the
    "all E4, always" inclusion guarantee holds regardless of their own helpful_count."""
    e4_lessons = []
    non_e4_lessons = []

    for filepath, fm, body in lessons:
        evidence = fm.get('evidence', 'E0')
        if evidence == 'E4':
            e4_lessons.append((filepath, fm, body))
        else:
            score = score_lesson(body, fm.get('tags', []), task_text)
            helpful, _harmful = _counts(fm)
            never_helpful = 1 if helpful == 0 else 0
            non_e4_lessons.append((filepath, fm, body, score, never_helpful))

    # Bucket first (never-helpful sorts after ever-helpful), then by score, then filename for ties.
    non_e4_lessons.sort(key=lambda x: (x[4], -x[3], str(x[0])))

    # Determine how many non-E4 to include
    remaining_slots = cap - len(e4_lessons)
    selected_non_e4 = non_e4_lessons[:max(0, remaining_slots)]

    # Combine: E4 first (sorted by filename), then top non-E4
    e4_lessons.sort(key=lambda x: str(x[0]))

    result = []
    for filepath, fm, body in e4_lessons:
        result.append((filepath, fm, body))
    for filepath, fm, body, score, never_helpful in selected_non_e4:
        result.append((filepath, fm, body))

    return result


def build_output(selected_lessons, exact_header):
    """Build the output string with exact header and bullet list. Each bullet gets a trailing
    '(helpful X/Y)' success-rate suffix when that lesson has any recorded helpful/harmful tags at all
    (X=helpful_count, Y=helpful_count+harmful_count) -- omitted entirely when there's no data yet, so
    an untagged lesson's line is unchanged from before this feature existed."""
    lines = [exact_header]
    for filepath, fm, body in selected_lessons:
        body_text = body.strip()
        text = body_text if body_text.startswith('- ') else f'- {body_text}'
        helpful, harmful = _counts(fm)
        total = helpful + harmful
        if total > 0:
            text = f'{text} (helpful {helpful}/{total})'
        lines.append(text)

    return '\n'.join(lines) + '\n'


def get_original_fallback():
    """Return the original 4 seed lessons as a fallback string."""
    return """## Known failure patterns — DO NOT SKIP
- A maker must literally execute git commit as its own final action before replying DONE — multiple times a maker replied DONE (or went idle) with real, uncommitted changes still sitting in the working tree. Claiming done is not the same as having committed.
- A selfcheck/regression test must call the actual function or code path it claims to test, not a separate reimplementation of the same logic — before shipping a new test, mutation-test it yourself: temporarily break the real fix, confirm the test then fails, then restore the fix. A test that still passes after the fix it's supposed to guard is removed is not a real test.
- Stay within the literal scope of the task — do not edit, delete, or 'clean up' lines unrelated to the stated change, even if they look adjacent, inconsistent, or improvable. If you notice something else that seems wrong, mention it in your DONE summary instead of changing it.
- Avoid long ad-hoc debugging one-liners typed directly at an interactive prompt for anything involving loops, symlinks, or recursion — write a small throwaway script file instead and run that. A shell syntax mistake in an inline one-liner can leave a runaway loop that doesn't actually stop, burning time and context without you noticing until it's very deep in.
"""


def _lessons_dir():
    lessons_dir = os.environ.get('SM_LESSONS_DIR')
    if lessons_dir:
        return lessons_dir
    script_dir = pathlib.Path(__file__).resolve().parent
    return script_dir / 'lessons'


def _lesson_id(filepath, lessons_dir):
    """Derive a stable id for a lesson file: its path relative to lessons_dir, no extension, '/'-joined.
    Best-effort -- falls back to the bare filename stem if filepath somehow isn't under lessons_dir."""
    try:
        rel = pathlib.Path(filepath).resolve().relative_to(pathlib.Path(lessons_dir).resolve())
        return rel.with_suffix('').as_posix()
    except (ValueError, OSError):
        return pathlib.Path(filepath).stem


def _lesson_ledger_path():
    """Resolve the injection-ledger path. Mirrors claim-ledger.py's _default_ledger_path() exactly --
    same anchoring rationale: every herdr-launched sub-agent-supervisor runs with its CWD set to its
    OWN linked worktree, so a plain CWD-relative default would give each one an unshared ledger file,
    silently splitting one task's injection history across worktrees instead of recording it in one
    shared place. `git rev-parse --git-common-dir` is the one physical location every worktree of a
    repo (including the primary checkout) agrees on; anchor at its PARENT for the normal case (a shared
    .git directory), or AT the common-dir itself for a bare repo/submodule (see claim-ledger.py's own
    header comment for why those two need the different anchor)."""
    if os.environ.get('SM_LESSON_LEDGER'):
        return pathlib.Path(os.environ['SM_LESSON_LEDGER'])
    if os.environ.get('SM_LOOP_STATE'):
        return pathlib.Path(os.environ['SM_LOOP_STATE']) / 'lesson-injections.jsonl'
    try:
        out = subprocess.run(['git', 'rev-parse', '--git-common-dir'], capture_output=True, text=True)
        if out.returncode == 0 and out.stdout.strip():
            common_dir = pathlib.Path(out.stdout.strip())
            if not common_dir.is_absolute():
                common_dir = pathlib.Path.cwd() / common_dir
            common_dir = common_dir.resolve()
            anchor = common_dir if common_dir.name != '.git' else common_dir.parent
            return anchor / '.secondmate' / 'lesson-injections.jsonl'
    except OSError:
        pass
    sys.stderr.write(
        "WARNING: lesson-lookup.py could not resolve a git-common-dir (not inside a git repo, or git "
        "not found) -- falling back to a CWD-relative ./.secondmate/lesson-injections.jsonl, which "
        "will NOT be shared across other worktrees/CWDs. Set SM_LESSON_LEDGER to a shared path for "
        "real cross-worktree injection logging.\n")
    return pathlib.Path('.secondmate') / 'lesson-injections.jsonl'


@contextlib.contextmanager
def _ledger_lock(ledger_path):
    # Same fcntl idiom as hold.py/claim-ledger.py's own _ledger_lock().
    if fcntl is None:
        yield; return
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    with open(str(ledger_path) + '.lock', 'w') as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def _log_injection(task_id, lesson_ids):
    """Append one record to the injection ledger. Never called unless the caller already wraps this
    in a try/except -- see main()'s fail-open guarantee: a logging failure must never prevent a lesson
    from being printed and injected."""
    if not _TASK_ID_RE.match(task_id or ''):
        return  # invalid task-id -- skip logging silently rather than ever raise into the caller
    ledger_path = _lesson_ledger_path()
    rec = {'ts': time.strftime('%Y-%m-%dT%H:%M:%S'), 'task_id': task_id, 'lesson_ids': lesson_ids}
    with _ledger_lock(ledger_path):
        ledger_path.parent.mkdir(parents=True, exist_ok=True)
        with ledger_path.open('a') as f:
            f.write(json.dumps(rec) + '\n')


def _parse_main_args(argv):
    task_text = ""
    task_id = None
    i = 0
    while i < len(argv):
        if argv[i] == '--task' and i + 1 < len(argv):
            task_text = argv[i + 1]; i += 2
        elif argv[i] == '--task-id' and i + 1 < len(argv):
            task_id = argv[i + 1]; i += 2
        else:
            i += 1
    return task_text, task_id


def main(argv=None):
    task_text, task_id = _parse_main_args(sys.argv[1:] if argv is None else argv)

    lessons_dir = _lessons_dir()

    # Exact header string - copy byte-for-byte from SKILL.md
    EXACT_HEADER = '## Known failure patterns — DO NOT SKIP'

    try:
        # Load and score lessons
        lessons = load_lessons(lessons_dir)

        # If no lessons found, print fallback
        if not lessons:
            print(get_original_fallback(), end='')
            return 0

        # Select lessons
        selected = select_lessons(lessons, task_text)

        # Build and print output
        output = build_output(selected, EXACT_HEADER)
        print(output, end='')

        # Best-effort injection logging -- must never affect the lookup/injection above in any way.
        if task_id:
            try:
                _log_injection(task_id, [_lesson_id(fp, lessons_dir) for fp, _fm, _body in selected])
            except Exception:
                pass

        return 0

    except Exception as e:
        # Any failure -> fallback to original 4 lessons
        print(get_original_fallback(), end='')
        return 0


def _resolve_lesson_path(lessons_dir, lesson_id):
    """Resolve a --lesson-id to a real file path, strictly confined to lessons_dir. Rejects anything
    not matching _LESSON_ID_RE (no '..' segments, no empty segments, no leading/trailing '/') AND
    double-checks the resolved path is actually still under lessons_dir (defense in depth against a
    symlink escape), the same layered posture scope-guard.py already uses for path confinement."""
    if not lesson_id or not _LESSON_ID_RE.match(lesson_id):
        return None
    lessons_path = pathlib.Path(lessons_dir).resolve()
    candidate = (lessons_path / (lesson_id + '.md')).resolve()
    try:
        candidate.relative_to(lessons_path)
    except ValueError:
        return None
    return candidate


def _increment_frontmatter_count(fm_text, field):
    """Increment `field: N` in raw frontmatter text (or append `field: 1` if absent), touching only
    that one line -- every other line (tags, evidence, earned-in, comments, unknown keys) is preserved
    exactly as-is. A full YAML round-trip serializer could reformat or silently drop fields this script
    never parses; a surgical text edit can't."""
    pattern = re.compile(r'\A(' + re.escape(field) + r')\s*:\s*(-?\d+)\s*\Z')
    lines = fm_text.splitlines()
    for i, line in enumerate(lines):
        m = pattern.match(line.strip())
        if m:
            new_val = max(0, int(m.group(2))) + 1
            leading = line[:len(line) - len(line.lstrip())]
            lines[i] = f'{leading}{field}: {new_val}'
            return '\n'.join(lines), new_val
    lines.append(f'{field}: 1')
    return '\n'.join(lines), 1


def _atomic_write(path, content):
    # Same discipline as round-state.md's own maker-prompt instruction: write to a temp file in the
    # SAME directory, then rename over the real path -- never a direct partial write.
    path = pathlib.Path(path)
    fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + '.', suffix='.tmp')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(content)
        os.replace(tmp_path, str(path))
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def cmd_tag(argv):
    """`tag --lesson-id ID --outcome helpful|harmful` -- supervisor-recorded feedback on one lesson,
    made by direct observation during a specific task (see SKILL.md's own evidence-discipline
    requirement for when this should and shouldn't be called). Never an automated correlation."""
    lesson_id_arg = None
    outcome = None
    i = 0
    while i < len(argv):
        if argv[i] == '--lesson-id' and i + 1 < len(argv):
            lesson_id_arg = argv[i + 1]; i += 2
        elif argv[i] == '--outcome' and i + 1 < len(argv):
            outcome = argv[i + 1]; i += 2
        else:
            i += 1

    if not lesson_id_arg:
        sys.stderr.write("tag: --lesson-id is required\n")
        return 2
    if outcome not in ('helpful', 'harmful'):
        sys.stderr.write("tag: --outcome must be 'helpful' or 'harmful'\n")
        return 2

    lessons_dir = _lessons_dir()
    path = _resolve_lesson_path(lessons_dir, lesson_id_arg)
    if path is None:
        sys.stderr.write(f"tag: invalid or out-of-bounds --lesson-id {lesson_id_arg!r}\n")
        return 2
    if not path.is_file():
        sys.stderr.write(f"tag: no lesson file found for --lesson-id {lesson_id_arg!r} ({path})\n")
        return 1

    content = path.read_text(encoding='utf-8')
    fm_text, body = _split_frontmatter(content)
    if fm_text is None:
        sys.stderr.write(f"tag: {path} has no parseable frontmatter\n")
        return 1

    field = 'helpful_count' if outcome == 'helpful' else 'harmful_count'
    new_fm_text, new_val = _increment_frontmatter_count(fm_text, field)
    new_content = '---\n' + new_fm_text + '\n---\n' + body
    _atomic_write(path, new_content)

    print(f"tagged {lesson_id_arg} as {outcome} ({field}={new_val})")
    return 0


def selfcheck():
    """Selfcheck assertions for lesson-lookup.py."""
    import tempfile as _tempfile
    import shutil

    # Test 1: With only 4 seed files present, all 4 are returned
    def test_e4_always_included():
        tmpdir = _tempfile.mkdtemp(prefix='lesson-selfcheck-')
        try:
            # Create seed files
            seed_content = """---
tags:
  - maker
  - workflow
evidence: E4
earned-in: seed
---
A maker must literally execute git commit as its own final action before replying DONE.
"""
            (pathlib.Path(tmpdir) / 'test1.md').write_text(seed_content)

            # Run lookup
            os.environ['SM_LESSONS_DIR'] = tmpdir
            # Import and run main
            import io
            from contextlib import redirect_stdout

            out = io.StringIO()
            with redirect_stdout(out):
                sys.argv = ['lesson-lookup.py', '--task', 'test task']
                try:
                    main()
                except SystemExit:
                    pass
            output = out.getvalue()

            # Count how many E4 lessons are in output
            e4_count = output.count('A maker must literally execute git commit')
            assert e4_count >= 1, f"Expected at least 1 E4 lesson in output, got:\n{output}"

            # Verify header is exact
            assert output.startswith('## Known failure patterns — DO NOT SKIP'), f"Header mismatch:\n{output[:100]}"
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            if 'SM_LESSONS_DIR' in os.environ:
                del os.environ['SM_LESSONS_DIR']

    # Test 2: Non-E4 lessons are scored by relevance
    def test_non_e4_scoring():
        tmpdir = _tempfile.mkdtemp(prefix='lesson-selfcheck-')
        try:
            # Create two non-E4 lessons with different relevance
            unrelated = """---
tags:
  - unrelated
  - topic
evidence: E0
earned-in: test
---
This lesson is about something completely different from the task.
"""
            (pathlib.Path(tmpdir) / 'unrelated.md').write_text(unrelated)

            relevant = """---
tags:
  - testing
  - regression
evidence: E0
earned-in: test
---
This lesson is about testing and regression which matches the task description well.
"""
            (pathlib.Path(tmpdir) / 'relevant.md').write_text(relevant)

            # Also add one E4 to ensure it's included
            e4_lesson = """---
tags:
  - maker
evidence: E4
earned-in: test
---
This is an E4 lesson that must always appear.
"""
            (pathlib.Path(tmpdir) / 'e4.md').write_text(e4_lesson)

            os.environ['SM_LESSONS_DIR'] = tmpdir

            out = io.StringIO()
            with redirect_stdout(out):
                sys.argv = ['lesson-lookup.py', '--task', 'testing and regression issues']
                try:
                    main()
                except SystemExit:
                    pass
            output = out.getvalue()

            # Both non-E4 should be present
            assert 'testing and regression' in output, f"Relevant lesson should be in output:\n{output}"
            assert 'completely different' in output, f"Unrelated lesson should still be in output (cap not yet reached):\n{output}"
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            if 'SM_LESSONS_DIR' in os.environ:
                del os.environ['SM_LESSONS_DIR']

    # Test 3: Malformed frontmatter is skipped
    def test_malformed_skip():
        tmpdir = _tempfile.mkdtemp(prefix='lesson-selfcheck-')
        try:
            # Create a valid lesson
            valid = """---
tags:
  - valid
evidence: E4
earned-in: test
---
This is valid.
"""
            (pathlib.Path(tmpdir) / 'valid.md').write_text(valid)

            # Create a malformed lesson (no --- markers)
            malformed = """This has no frontmatter at all.
"""
            (pathlib.Path(tmpdir) / 'malformed.md').write_text(malformed)

            os.environ['SM_LESSONS_DIR'] = tmpdir

            out = io.StringIO()
            err = io.StringIO()
            with redirect_stdout(out):
                with redirect_stderr(err):
                    sys.argv = ['lesson-lookup.py', '--task', 'test']
                    try:
                        main()
                    except SystemExit:
                        pass
            output = out.getvalue()
            errors = err.getvalue()

            # Should still work, skip malformed
            assert 'valid' in output, f"Valid lesson should be in output:\n{output}"
            # Malformed should generate warning to stderr
            assert 'malformed' in errors.lower(), f"Expected warning about malformed file in stderr:\n{errors}"
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            if 'SM_LESSONS_DIR' in os.environ:
                del os.environ['SM_LESSONS_DIR']

    # Test 4: Fallback to original when directory doesn't exist
    def test_fallback_on_missing():
        os.environ['SM_LESSONS_DIR'] = '/nonexistent/path/that/does/not/exist'

        out = io.StringIO()
        with redirect_stdout(out):
            sys.argv = ['lesson-lookup.py', '--task', 'test']
            try:
                main()
            except SystemExit:
                pass
        output = out.getvalue()

        # Should get original fallback
        assert output.startswith('## Known failure patterns — DO NOT SKIP'), f"Should get fallback header:\n{output[:100]}"
        assert 'git commit' in output, f"Should contain original content:\n{output}"

    # Test 5: Tag-based scoring beats body-text when body is identical but tags differ
    def test_tag_scoring_beats_body():
        """Test that tag-based scoring works when body text is identical but tags differ."""
        tmpdir = _tempfile.mkdtemp(prefix='lesson-selfcheck-')
        try:
            # Two non-E4 lessons with IDENTICAL body text but DIFFERENT tags
            # The lesson with matching tags should rank higher
            generic_body = """This lesson has generic content and should be scored based on tags, not body text."""

            # This lesson has 'testing' in tags
            with_tags = f"""---
tags:
  - testing
  - specific
evidence: E0
earned-in: test
---
{generic_body}
"""
            # Two non-E4 lessons with DIFFERENT body text markers (to distinguish in output)
            # The tagged one has 'testing' in tags, the other doesn't
            # Both have unique body text so we can track their positions

            # This lesson has 'testing' in tags - named 'z-tagged' so filename loses tie-break
            with_tags = '''---
tags:
  - testing
  - specific
evidence: E0
earned-in: test
---
Z-TAGGED-LESSON: This lesson body has unique marker Z-TAGGED-LESSON for position comparison.
'''
            (pathlib.Path(tmpdir) / 'z-tagged.md').write_text(with_tags)  # renamed for filename tie-break test

            # This lesson has 'unrelated' in tags (no overlap with task)
            # Named 'a-untagged' so filename wins tie-break if tags were ignored
            without_tags = '''---
tags:
  - unrelated
  - generic
evidence: E0
earned-in: test
---
A-UNTAGGED-LESSON: This lesson body has unique marker A-UNTAGGED-LESSON for position comparison.
'''
            (pathlib.Path(tmpdir) / 'a-untagged.md').write_text(without_tags)

            # Also add one E4 to ensure it's included
            e4_lesson = """---
tags:
  - maker
evidence: E4
earned-in: test
---
This is an E4 lesson that must always appear.
"""
            (pathlib.Path(tmpdir) / 'e4.md').write_text(e4_lesson)

            os.environ['SM_LESSONS_DIR'] = tmpdir

            out = io.StringIO()
            with redirect_stdout(out):
                sys.argv = ['lesson-lookup.py', '--task', 'testing and regression issues']
                try:
                    main()
                except SystemExit:
                    pass
            output = out.getvalue()

            # Both non-E4 lessons should be present (cap not reached)
            assert 'Z-TAGGED-LESSON' in output, f"Tagged lesson should be in output:\n{output}"
            assert 'A-UNTAGGED-LESSON' in output, f"Untagged lesson should be in output:\n{output}"
            # The lesson with 'testing' tag should be ranked higher
            # Verify the tagged one appears before the untagged one (by position in output)
            tagged_pos = output.find('Z-TAGGED-LESSON')
            untagged_pos = output.find('A-UNTAGGED-LESSON')
            assert tagged_pos >= 0, f"Z-TAGGED-LESSON not found in output:\n{output}"
            assert untagged_pos >= 0, f"A-UNTAGGED-LESSON not found in output:\n{output}"
            assert tagged_pos < untagged_pos, f"Tagged lesson should rank higher than untagged:\n{output}"
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            if 'SM_LESSONS_DIR' in os.environ:
                del os.environ['SM_LESSONS_DIR']

    # Test 6: a lesson ever marked helpful outranks a MORE relevant lesson that never has -- bucketing
    # overrides raw relevance score, but score still governs ordering within a bucket (checked
    # separately by test_tag_scoring_beats_body above, whose two lessons both have helpful_count=0).
    def test_helpful_bucket_beats_relevance():
        tmpdir = _tempfile.mkdtemp(prefix='lesson-selfcheck-')
        try:
            proven_but_irrelevant = '''---
tags:
  - unrelated
evidence: E0
earned-in: test
helpful_count: 2
harmful_count: 1
---
PROVEN-LESSON: no overlap with the task text at all.
'''
            (pathlib.Path(tmpdir) / 'z-proven.md').write_text(proven_but_irrelevant)  # 'z' so filename tie-break would put it LAST if score/bucket were ignored

            unproven_but_relevant = '''---
tags:
  - testing
  - regression
evidence: E0
earned-in: test
---
UNPROVEN-LESSON: testing and regression testing regression, matches the task text heavily.
'''
            (pathlib.Path(tmpdir) / 'a-unproven.md').write_text(unproven_but_relevant)  # 'a' so filename tie-break would put it FIRST if score/bucket were ignored

            os.environ['SM_LESSONS_DIR'] = tmpdir
            out = io.StringIO()
            with redirect_stdout(out):
                sys.argv = ['lesson-lookup.py', '--task', 'testing and regression testing regression']
                try:
                    main()
                except SystemExit:
                    pass
            output = out.getvalue()
            proven_pos = output.find('PROVEN-LESSON')
            unproven_pos = output.find('UNPROVEN-LESSON')
            assert proven_pos >= 0 and unproven_pos >= 0, f"both lessons should appear:\n{output}"
            assert proven_pos < unproven_pos, (
                f"a lesson with helpful_count > 0 must rank ABOVE a never-helpful lesson even when the "
                f"never-helpful one scores far higher on raw relevance:\n{output}")
            # success-rate suffix rendered for the lesson with recorded counts, omitted for the one without
            assert '(helpful 2/3)' in output, f"expected a rendered success-rate suffix:\n{output}"
            assert 'UNPROVEN-LESSON: testing and regression testing regression, matches the task text heavily. (helpful' not in output, (
                f"a lesson with zero recorded counts must not get a success-rate suffix:\n{output}")
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            if 'SM_LESSONS_DIR' in os.environ:
                del os.environ['SM_LESSONS_DIR']

    # Test 7: --task-id logging is anchored via git-common-dir (like claim-ledger.py), fail-open on an
    # invalid task-id, and never affects the printed lesson output either way.
    def test_task_id_logging():
        tmpdir = _tempfile.mkdtemp(prefix='lesson-selfcheck-')
        ledger_dir = _tempfile.mkdtemp(prefix='lesson-ledger-')
        try:
            seed = """---
tags:
  - maker
evidence: E4
earned-in: test
---
An E4 lesson body for logging test.
"""
            (pathlib.Path(tmpdir) / 'seed.md').write_text(seed)
            os.environ['SM_LESSONS_DIR'] = tmpdir
            ledger_path = pathlib.Path(ledger_dir) / 'lesson-injections.jsonl'
            os.environ['SM_LESSON_LEDGER'] = str(ledger_path)

            out = io.StringIO()
            with redirect_stdout(out):
                sys.argv = ['lesson-lookup.py', '--task', 'demo', '--task-id', 'demo-task-1']
                try:
                    main()
                except SystemExit:
                    pass
            output = out.getvalue()
            assert 'An E4 lesson body' in output, "lesson injection must still happen with --task-id present"
            assert ledger_path.exists(), "a valid --task-id should create the injection ledger"
            recs = [json.loads(l) for l in ledger_path.read_text().splitlines() if l.strip()]
            assert len(recs) == 1 and recs[0]['task_id'] == 'demo-task-1', f"expected exactly one logged record: {recs}"
            assert recs[0]['lesson_ids'] == ['seed'], f"expected the selected lesson's id to be logged: {recs}"

            # An INVALID task-id must skip logging silently, never raise, and never change the printed output.
            bad_ledger = pathlib.Path(ledger_dir) / 'should-not-exist.jsonl'
            os.environ['SM_LESSON_LEDGER'] = str(bad_ledger)
            out2 = io.StringIO()
            with redirect_stdout(out2):
                sys.argv = ['lesson-lookup.py', '--task', 'demo', '--task-id', 'bad id with spaces']
                try:
                    main()
                except SystemExit:
                    pass
            assert out2.getvalue() == output, "output must be identical whether or not --task-id logs"
            assert not bad_ledger.exists(), "an invalid --task-id must never create/append to the ledger"

            # No --task-id at all must also never create a ledger.
            no_id_ledger = pathlib.Path(ledger_dir) / 'no-task-id.jsonl'
            os.environ['SM_LESSON_LEDGER'] = str(no_id_ledger)
            with redirect_stdout(io.StringIO()):
                sys.argv = ['lesson-lookup.py', '--task', 'demo']
                try:
                    main()
                except SystemExit:
                    pass
            assert not no_id_ledger.exists(), "omitting --task-id must never create the ledger"
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            shutil.rmtree(ledger_dir, ignore_errors=True)
            for k in ('SM_LESSONS_DIR', 'SM_LESSON_LEDGER'):
                if k in os.environ:
                    del os.environ[k]

    # Test 8: a logging failure (an unwritable ledger directory) must never prevent the real lesson
    # output from being printed -- the fail-open guarantee this whole feature is required to preserve.
    def test_logging_failure_is_fail_open():
        tmpdir = _tempfile.mkdtemp(prefix='lesson-selfcheck-')
        try:
            seed = """---
tags:
  - maker
evidence: E4
earned-in: test
---
Fail-open logging test lesson.
"""
            (pathlib.Path(tmpdir) / 'seed.md').write_text(seed)
            os.environ['SM_LESSONS_DIR'] = tmpdir
            # Point the ledger at a path whose parent can never be created (a file, not a directory,
            # sitting where a directory component is required) -- forces _log_injection to raise.
            blocker = pathlib.Path(tmpdir) / 'blocker-is-a-file'
            blocker.write_text('x')
            os.environ['SM_LESSON_LEDGER'] = str(blocker / 'nested' / 'ledger.jsonl')

            out = io.StringIO()
            with redirect_stdout(out):
                sys.argv = ['lesson-lookup.py', '--task', 'demo', '--task-id', 'fail-open-task']
                try:
                    rc = main()
                except SystemExit:
                    rc = None
            output = out.getvalue()
            assert 'Fail-open logging test lesson' in output, f"a logging failure must never suppress the real lesson output:\n{output}"
            assert 'A maker must literally execute git commit' not in output, (
                f"a logging failure must be swallowed at the logging call site, not bubble up and trigger "
                f"a second, duplicate fallback print on top of the already-printed real output:\n{output}")
            assert rc == 0 or rc is None, "a logging failure must never turn into a nonzero exit from main()"
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            for k in ('SM_LESSONS_DIR', 'SM_LESSON_LEDGER'):
                if k in os.environ:
                    del os.environ[k]

    # Test 9: with SM_LESSON_LEDGER and SM_LOOP_STATE both unset, two lesson-lookup.py invocations from
    # DIFFERENT CWDs inside the SAME git repo (the primary checkout + a linked worktree) must resolve to
    # the IDENTICAL default ledger file -- the exact bug class claim-ledger.py's own default path once
    # had (and this repo's verdict-hardening task hit again independently): a plain CWD-relative default
    # would give each worktree its own unshared ledger, since every herdr-launched sub-agent runs with
    # its CWD set to its own worktree. Only a real subprocess per CWD can test this faithfully.
    def test_default_ledger_anchoring():
        tmp = _tempfile.mkdtemp(prefix='lesson-ledger-pathcheck-')
        try:
            repo = os.path.join(tmp, 'repo')
            subprocess.run(['git', 'init', '-q', '-b', 'main', repo], check=True)
            subprocess.run(['git', '-C', repo, 'config', 'user.email', 'a@a'], check=True)
            subprocess.run(['git', '-C', repo, 'config', 'user.name', 'a'], check=True)
            with open(os.path.join(repo, 'f'), 'w') as f:
                f.write('x')
            subprocess.run(['git', '-C', repo, 'add', '-A'], check=True)
            subprocess.run(['git', '-C', repo, 'commit', '-q', '-m', 'init'], check=True)
            wt = os.path.join(tmp, 'wt')
            subprocess.run(['git', '-C', repo, 'worktree', 'add', '-q', '-b', 'feat', wt, 'main'], check=True)

            lessons_dir = os.path.join(tmp, 'lessons')
            os.makedirs(lessons_dir)
            with open(os.path.join(lessons_dir, 'seed.md'), 'w') as f:
                f.write("---\ntags:\n  - x\nevidence: E4\nearned-in: test\n---\nanchor test lesson.\n")

            env = {k: v for k, v in os.environ.items() if k not in ('SM_LESSON_LEDGER', 'SM_LOOP_STATE')}
            env['SM_LESSONS_DIR'] = lessons_dir

            def _cli(cwd, extra_args):
                return subprocess.run([sys.executable, _SCRIPT_PATH, '--task', 'x'] + extra_args,
                                       cwd=cwd, env=env, capture_output=True, text=True)

            p1 = _cli(repo, ['--task-id', 'shared-task-1'])
            assert p1.returncode == 0, f"lookup from the primary checkout should succeed: {p1.stderr}"
            p2 = _cli(wt, ['--task-id', 'shared-task-2'])
            assert p2.returncode == 0, f"lookup from a linked worktree should succeed: {p2.stderr}"

            common_dir = subprocess.run(['git', '-C', repo, 'rev-parse', '--git-common-dir'],
                                         capture_output=True, text=True, check=True).stdout.strip()
            common_dir_path = pathlib.Path(common_dir)
            if not common_dir_path.is_absolute():
                common_dir_path = pathlib.Path(repo) / common_dir_path
            expected = common_dir_path.resolve().parent / '.secondmate' / 'lesson-injections.jsonl'
            assert expected.exists(), f"expected the shared default ledger at {expected}"
            recs = [json.loads(line) for line in expected.read_text().splitlines() if line.strip()]
            task_ids = {r.get('task_id') for r in recs}
            assert {'shared-task-1', 'shared-task-2'} <= task_ids, (
                f"both the primary-checkout and linked-worktree invocations should have logged into "
                f"the SAME shared default ledger, got task_ids={task_ids}")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # Test 10: the `tag` subcommand increments the right counter, preserves every other line in the
    # file byte-for-byte, is atomic (temp file + rename), and rejects a path-traversal lesson-id.
    def test_tag_subcommand():
        tmpdir = _tempfile.mkdtemp(prefix='lesson-selfcheck-')
        try:
            (pathlib.Path(tmpdir) / 'sub').mkdir()
            original = """---
tags:
  - maker
  - workflow
evidence: E4
earned-in: seed
---

A body paragraph that must survive byte-for-byte across a tag edit.
"""
            fpath = pathlib.Path(tmpdir) / 'sub' / 'lesson.md'
            fpath.write_text(original)
            os.environ['SM_LESSONS_DIR'] = tmpdir

            rc = cmd_tag(['--lesson-id', 'sub/lesson', '--outcome', 'helpful'])
            assert rc == 0, "first tag should succeed"
            content1 = fpath.read_text()
            assert 'helpful_count: 1' in content1, f"expected helpful_count: 1 after first tag:\n{content1}"
            assert 'harmful_count' not in content1, "harmful_count must not appear until harmful is tagged"
            assert 'A body paragraph that must survive byte-for-byte across a tag edit.' in content1
            assert '  - maker' in content1 and '  - workflow' in content1, "tags list must be preserved"
            assert "earned-in: seed" in content1, "earned-in must be preserved"

            rc = cmd_tag(['--lesson-id', 'sub/lesson', '--outcome', 'helpful'])
            assert rc == 0
            content2 = fpath.read_text()
            assert 'helpful_count: 2' in content2, f"expected helpful_count: 2 after a second tag:\n{content2}"

            rc = cmd_tag(['--lesson-id', 'sub/lesson', '--outcome', 'harmful'])
            assert rc == 0
            content3 = fpath.read_text()
            assert 'helpful_count: 2' in content3 and 'harmful_count: 1' in content3, f"counts wrong:\n{content3}"

            # frontmatter round-trips through parse_frontmatter correctly after tagging.
            fm, body = parse_frontmatter(content3)
            assert fm.get('tags') == ['maker', 'workflow'], f"tags parse broken after tag edits: {fm}"
            assert fm.get('helpful_count') == '2' and fm.get('harmful_count') == '1', f"counts parse broken: {fm}"

            # a lesson file that predates these fields (no helpful_count/harmful_count at all) parses to 0/0.
            no_counts_fm = {'evidence': 'E4'}
            assert _counts(no_counts_fm) == (0, 0), "missing counts must default to (0, 0)"

            # path-traversal / out-of-bounds lesson-ids are rejected, never touching any file.
            for bad_id in ('../etc/passwd', '/etc/passwd', 'sub/../../../etc/passwd', '', 'bad id', 'a//b'):
                rc = cmd_tag(['--lesson-id', bad_id, '--outcome', 'helpful'])
                assert rc != 0, f"bad lesson-id {bad_id!r} should be rejected"

            # unknown lesson-id (valid shape, no such file) -> nonzero, no crash.
            rc = cmd_tag(['--lesson-id', 'sub/does-not-exist', '--outcome', 'helpful'])
            assert rc != 0, "a nonexistent lesson-id should fail cleanly"

            # bad --outcome value is rejected.
            rc = cmd_tag(['--lesson-id', 'sub/lesson', '--outcome', 'meh'])
            assert rc != 0, "an invalid --outcome should be rejected"
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            if 'SM_LESSONS_DIR' in os.environ:
                del os.environ['SM_LESSONS_DIR']

    # Run all tests
    import os, io
    from contextlib import redirect_stdout, redirect_stderr

    test_e4_always_included()
    test_non_e4_scoring()
    test_malformed_skip()
    test_fallback_on_missing()
    test_tag_scoring_beats_body()  # test that tag-based scoring beats filename tie-break
    test_helpful_bucket_beats_relevance()
    test_task_id_logging()
    test_logging_failure_is_fail_open()
    test_default_ledger_anchoring()
    test_tag_subcommand()

    # Test 10: All 4 real shipped seed files parse correctly and are evidence:E4
    def test_real_seed_files():
        """Assert all 4 shipped seed files parse without error and are classified E4."""
        script_dir = pathlib.Path(__file__).resolve().parent
        lessons_dir = script_dir / 'lessons'

        # Check all 4 expected seed files exist and parse as E4
        expected_files = [
            lessons_dir / 'workflow' / 'commit-before-done.md',
            lessons_dir / 'testing' / 'mutation-test-your-tests.md',
            lessons_dir / 'workflow' / 'stay-in-literal-scope.md',
            lessons_dir / 'debugging' / 'avoid-ad-hoc-debug-loops.md',
        ]

        for fpath in expected_files:
            assert fpath.exists(), f"Expected seed file missing: {fpath}"
            content = fpath.read_text(encoding='utf-8')
            fm, body = parse_frontmatter(content)
            assert fm is not None, f"Failed to parse frontmatter in {fpath}"
            assert fm.get('evidence') == 'E4', f"Expected E4 evidence in {fpath}, got {fm.get('evidence')}"
            assert fm.get('earned-in') == 'seed', f"Expected 'seed' earned-in in {fpath}, got {fm.get('earned-in')}"
            # CRITICAL: Assert tags are NOT empty (this test catches the bug we fixed)
            tags = fm.get('tags', [])
            assert len(tags) > 0, f"Tags should not be empty in {fpath}, got {tags}"
            # At least one tag should be a known category or related tag
            assert any(t in tags for t in ['maker', 'debugging', 'testing', 'workflow', 'scope', 'focus']), f"Expected at least one known tag in {fpath}, got {tags}"
            # These 4 seed files predate helpful_count/harmful_count -- must still default to (0, 0).
            assert _counts(fm) == (0, 0), f"seed file counts should default to (0, 0): {fpath}"

    test_real_seed_files()

    print("ok")


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'selfcheck':
        selfcheck()
    elif len(sys.argv) > 1 and sys.argv[1] == 'tag':
        sys.exit(cmd_tag(sys.argv[2:]))
    else:
        sys.exit(main())
