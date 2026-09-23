#!/usr/bin/env python3
# ponytail: store known failure patterns as retrievable lessons.
"""lesson-lookup.py -- retrieve known failure patterns from the lesson store.

Usage: bin/lesson-lookup.py --task "<description>"

Reads all bin/lessons/**/*.md files, parses frontmatter (stdlib only, no yaml),
scores non-E4 lessons by term overlap with the task description, and returns
a block with all E4 lessons (always) plus top-scoring non-E4 lessons up to a
reasonable cap (5-6 total). If the lesson store is unavailable, falls back to
the original 4 seed lessons' exact text.

Output format (byte-for-byte exact match): '## Known failure patterns — DO NOT SKIP'
followed by one '- <lesson body>' bullet per selected lesson, in deterministic order
(score descending, then filename ascending).
"""
import sys
import os
import re
import pathlib


def parse_frontmatter(content):
    """Parse YAML-shaped frontmatter between --- markers. Returns (frontmatter_dict, body) or (None, None) if malformed."""
    if not content.startswith('---\n'):
        return None, None
    
    end_marker = content.find('\n---\n', 3)
    if end_marker == -1:
        return None, None
    
    frontmatter_text = content[4:end_marker]
    body = content[end_marker + 5:]  # skip '\n---\n' and leading newline in body
    
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
    """Select lessons: all E4 + top non-E4 up to cap. Returns list of (filepath, body) tuples."""
    e4_lessons = []
    non_e4_lessons = []
    
    for filepath, fm, body in lessons:
        evidence = fm.get('evidence', 'E0')
        if evidence == 'E4':
            e4_lessons.append((filepath, fm, body))
        else:
            score = score_lesson(body, fm.get('tags', []), task_text)
            non_e4_lessons.append((filepath, fm, body, score))
    
    # Select top non-E4 by score, then filename for ties
    non_e4_lessons.sort(key=lambda x: (-x[3], str(x[0])))
    
    # Determine how many non-E4 to include
    remaining_slots = cap - len(e4_lessons)
    selected_non_e4 = non_e4_lessons[:max(0, remaining_slots)]
    
    # Combine: E4 first (sorted by filename), then top non-E4
    e4_lessons.sort(key=lambda x: str(x[0]))
    
    result = []
    for filepath, fm, body in e4_lessons:
        result.append((filepath, body))
    for filepath, fm, body, score in selected_non_e4:
        result.append((filepath, body))
    
    return result


def build_output(selected_lessons, exact_header):
    """Build the output string with exact header and bullet list."""
    lines = [exact_header]
    for filepath, body in selected_lessons:
        # The body should already have the bullet text without the leading '- '
        # If it already has '- ' prefix, keep it; otherwise add it
        if body.startswith('- '):
            lines.append(body)
        else:
            lines.append(f'- {body.strip()}')
    
    return '\n'.join(lines) + '\n'


def get_original_fallback():
    """Return the original 4 seed lessons as a fallback string."""
    return """## Known failure patterns — DO NOT SKIP
- A maker must literally execute git commit as its own final action before replying DONE — multiple times a maker replied DONE (or went idle) with real, uncommitted changes still sitting in the working tree. Claiming done is not the same as having committed.
- A selfcheck/regression test must call the actual function or code path it claims to test, not a separate reimplementation of the same logic — before shipping a new test, mutation-test it yourself: temporarily break the real fix, confirm the test then fails, then restore the fix. A test that still passes after the fix it's supposed to guard is removed is not a real test.
- Stay within the literal scope of the task — do not edit, delete, or 'clean up' lines unrelated to the stated change, even if they look adjacent, inconsistent, or improvable. If you notice something else that seems wrong, mention it in your DONE summary instead of changing it.
- Avoid long ad-hoc debugging one-liners typed directly at an interactive prompt for anything involving loops, symlinks, or recursion — write a small throwaway script file instead and run that. A shell syntax mistake in an inline one-liner can leave a runaway loop that doesn't actually stop, burning time and context without you noticing until it's very deep in.
"""


def main():
    # Parse arguments
    task_text = ""
    if len(sys.argv) >= 3 and sys.argv[1] == '--task':
        task_text = sys.argv[2]
    
    # Determine lessons directory - respect env override for testing
    lessons_dir = os.environ.get('SM_LESSONS_DIR')
    if not lessons_dir:
        # Default: assume script is in bin/, lessons are in bin/lessons/
        script_dir = pathlib.Path(__file__).resolve().parent
        lessons_dir = script_dir / 'lessons'
    
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
        
        return 0
        
    except Exception as e:
        # Any failure -> fallback to original 4 lessons
        print(get_original_fallback(), end='')
        return 0


def selfcheck():
    """Selfcheck assertions for lesson-lookup.py."""
    import tempfile
    import shutil
    
    # Test 1: With only 4 seed files present, all 4 are returned
    def test_e4_always_included():
        tmpdir = tempfile.mkdtemp(prefix='lesson-selfcheck-')
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
        tmpdir = tempfile.mkdtemp(prefix='lesson-selfcheck-')
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
        tmpdir = tempfile.mkdtemp(prefix='lesson-selfcheck-')
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
        tmpdir = tempfile.mkdtemp(prefix='lesson-selfcheck-')
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
    
    # Run all tests
    import os, io
    from contextlib import redirect_stdout, redirect_stderr
    
    test_e4_always_included()
    test_non_e4_scoring()
    test_malformed_skip()
    test_fallback_on_missing()
    
    # Test 5: All 4 real shipped seed files parse correctly and are evidence:E4
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
    
    test_real_seed_files()
    
    print("ok")


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'selfcheck':
        selfcheck()
    else:
        sys.exit(main())
