#!/usr/bin/env python3
# ponytail: prefer the fenced ```json envelope; else top-level {verdict} objects; fail-closed on conflict.
"""verdict.py -- read a checker's output, extract its JSON verdict envelope, branch deterministically.

  verdict.py [FILE]   # FILE or stdin = checker output; prints the verdict word
                      # exit: 0=pass  1=fail  2=error/refused/ambiguous/malformed
  verdict.py --lenses <comma-separated-list> [FILE]  # additionally cross-check lens_coverage
  verdict.py selfcheck

The checker is instructed to END with a fenced ```json {"verdict":...} block, so we prefer verdicts found
inside fenced blocks. If there are none, we fall back to scanning TOP-LEVEL {...} objects only — never nested
ones, so a stray "verdict" key buried in prose or structured data can't be mistaken for the envelope.
Conflicting verdicts fail closed (ambiguous). The supervisor branches on the exit code, not the prose.
"""
import json, re, sys, os, time, argparse, pathlib, contextlib
try:
    import fcntl
except ImportError:  # non-Unix (e.g. Windows) -> best-effort, no locking
    fcntl = None

VALID = {"pass", "fail", "error", "refused"}
EXIT = {"pass": 0, "fail": 1, "error": 2, "refused": 2, "malformed": 2, "ambiguous": 2}

def get_ledger_path():
    """Get ledger path, reading SM_LENS_COVERAGE_LEDGER env var."""
    return pathlib.Path(os.environ.get("SM_LENS_COVERAGE_LEDGER", "audit/lens-coverage.jsonl"))


def _top_objects(text):
    """Yield DEPTH-0 balanced {...} spans only (ignoring braces inside JSON strings)."""
    depth = 0; start = None; in_str = False; esc = False
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
                yield text[start:i + 1]


def _valid_verdicts(text):
    out = []
    for span in _top_objects(text):
        try:
            o = json.loads(span)
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("verdict") in VALID:
            out.append(o["verdict"])
    return out


def _extract_envelope_with_verdict(text, verdict_word):
    """Find and return the envelope dict that contains verdict_word."""
    for pattern in (r"```json\s*\n(.*?)```", r"```\s*\n(.*?)```"):
        blocks = re.findall(pattern, text, re.DOTALL)
        for block in reversed(blocks):
            for span in _top_objects(block):
                try:
                    o = json.loads(span)
                    if isinstance(o, dict) and o.get("verdict") == verdict_word:
                        return o
                except ValueError:
                    continue
    # Fallback to top-level objects
    for span in _top_objects(text):
        try:
            o = json.loads(span)
            if isinstance(o, dict) and o.get("verdict") == verdict_word:
                return o
        except ValueError:
            continue
    return None


@contextlib.contextmanager
def _ledger_lock():
    """Same fcntl idiom as hold.py's _ledger_lock(): serialize concurrent mutations."""
    if fcntl is None:
        yield; return
    ledger_path = get_ledger_path()
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    with open(str(ledger_path) + ".lock", "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def _record_lens_coverage(requested, covered, missing, verdict):
    """Append one JSON line to audit/lens-coverage.jsonl."""
    try:
        with _ledger_lock():
            ledger_path = get_ledger_path()
            ledger_path.parent.mkdir(parents=True, exist_ok=True)
            with open(ledger_path, "a") as f:
                json.dump({
                    "timestamp": time.time(),
                    "requested": requested,
                    "covered": covered,
                    "missing": missing,
                    "verdict": verdict
                }, f)
                f.write("\n")
    except Exception as e:
        sys.stderr.write(f"warning: ledger write failed: {e}\n")
        # A ledger-write failure itself is a loud stderr WARNING, never a silent loss
        # Matching merge-ledger.jsonl's own documented precedent exactly


def read_verdict_with_envelope(text):
    """Read verdict from text, validating findings for fail verdicts.
    Returns (verdict_word, exit_code, envelope_or_none)."""
    # The checker is instructed to END with a fenced ```json envelope as its FINAL output, so the real
    # verdict is the LAST json-fenced block; example envelopes quoted earlier in the findings are ignored
    # (finding #3: a `{"verdict":"pass"}` example inside a finding must not be mistaken for the verdict).
    for pattern in (r"```json\s*\n(.*?)```", r"```\s*\n(.*?)```"):
        blocks = re.findall(pattern, text, re.DOTALL)
        for block in reversed(blocks):                 # last matching block wins
            vs = _valid_verdicts(block)
            if vs:
                if len(set(vs)) > 1:                    # one block, conflicting verdicts -> fail closed
                    return "ambiguous", EXIT["ambiguous"], None
                # Extract envelope to validate findings for "fail" verdicts
                verdict_word = vs[-1]
                envelope = _extract_envelope_with_verdict(text, verdict_word)
                if verdict_word == "fail":
                    if not envelope:
                        return "ambiguous", EXIT["ambiguous"], envelope
                    # Validate findings for fail verdict
                    findings = envelope.get("findings", [])
                    if not isinstance(findings, list):
                        return "ambiguous", EXIT["ambiguous"], envelope
                    if not findings:  # empty findings array on fail verdict is invalid
                        return "ambiguous", EXIT["ambiguous"], envelope
                    # Validate each finding
                    for finding in findings:
                        if not isinstance(finding, str):
                            return "ambiguous", EXIT["ambiguous"], envelope
                        # Must contain either file:line pattern OR literal [NOLOC]
                        if "[NOLOC]" in finding:
                            continue  # explicit escape hatch
                        # Match file:line pattern (e.g., file.py:42 or file.py:42,99)
                        if not re.search(r'[^\s:]+:\d+(?:,\d+)*', finding):
                            return "ambiguous", EXIT["ambiguous"], envelope
                return verdict_word, EXIT[verdict_word], envelope
    # no fenced block at all: fall back to top-level objects; conflicting bare verdicts fail closed
    vs = _valid_verdicts(text)
    if not vs:
        return "malformed", EXIT["malformed"], None
    if len(set(vs)) > 1:
        return "ambiguous", EXIT["ambiguous"], None
    # Validate findings for fail verdicts from top-level objects too
    verdict_word = vs[-1]
    envelope = _extract_envelope_with_verdict(text, verdict_word)
    if verdict_word == "fail":
        if not envelope:
            return "ambiguous", EXIT["ambiguous"], envelope
        # Validate findings for fail verdict
        findings = envelope.get("findings", [])
        if not isinstance(findings, list):
            return "ambiguous", EXIT["ambiguous"], envelope
        if not findings:  # empty findings array on fail verdict is invalid
            return "ambiguous", EXIT["ambiguous"], envelope
        # Validate each finding
        for finding in findings:
            if not isinstance(finding, str):
                return "ambiguous", EXIT["ambiguous"], envelope
            # Must contain either file:line pattern OR literal [NOLOC]
            if "[NOLOC]" in finding:
                continue  # explicit escape hatch
            # Match file:line pattern (e.g., file.py:42 or file.py:42,99)
            if not re.search(r'[^\s:]+:\d+(?:,\d+)*', finding):
                return "ambiguous", EXIT["ambiguous"], envelope
    return verdict_word, EXIT[verdict_word], envelope


def read_verdict(text):
    """Read verdict from text, validating findings for fail verdicts."""
    return read_verdict_with_envelope(text)[0]


def check_lens_coverage(requested_lenses, envelope):
    """Check that every requested lens appears in envelope's lens_coverage.
    Returns (missing_lenses, covered_lenses)."""
    if not envelope:
        return requested_lenses, []  # all missing
    lens_coverage = envelope.get("lens_coverage", {})
    if not isinstance(lens_coverage, dict):
        return requested_lenses, []  # invalid format, treat as all missing
    covered = []
    missing = []
    for lens in requested_lenses:
        if lens_coverage.get(lens):  # truthy value
            covered.append(lens)
        else:
            missing.append(lens)
    return missing, covered


def main(argv):
    parser = argparse.ArgumentParser(description="Extract verdict from checker output")
    parser.add_argument("file", nargs="?", help="checker output file (default: stdin)")
    parser.add_argument("--lenses", help="comma-separated list of lens names to require coverage for")
    args = parser.parse_args(argv)
    
    if argv and argv[0] == "selfcheck":
        # Run selfcheck tests
        def rv(text):
            return read_verdict_with_envelope(text)[:2]  # just (word, code)
        
        # First test: failing verdict with invalid finding "a" should be ambiguous
        assert rv('x\n```json\n{"verdict":"fail","findings":["a"],"diagnostic":""}\n```\ny') == ("ambiguous", 2)  # invalid finding
        # Valid finding with file:line should pass
        assert rv('x\n```json\n{"verdict":"fail","findings":["bin/doctor.sh:322,419 fresh HOME without .pi/agent makes both Bedrock atomic writes fail [CONFIRMED]"],"diagnostic":""}\n```\ny') == ("fail", 1)
        # [NOLOC] escape hatch should work
        assert rv('x\n```json\n{"verdict":"fail","findings":["[NOLOC] process design defect with no single fixed line"],"diagnostic":""}\n```\ny') == ("fail", 1)
        # Empty findings on fail should be ambiguous
        assert rv('finding: `{"verdict":"pass"}` example\n```json\n{"verdict":"fail","findings":[]}\n```') == ("ambiguous", 2)  # empty findings on fail
        # Non-string finding should be ambiguous
        assert rv('x\n```json\n{"verdict":"fail","findings":[123],"diagnostic":""}\n```\ny') == ("ambiguous", 2)  # non-string finding
        assert rv('```json\n{"verdict":"pass"}\n```') == ("pass", 0)
        assert rv('no json at all') == ("malformed", 2)
        assert rv('{"verdict":"bogus"}') == ("malformed", 2)
        assert rv('{"report":{"verdict":"pass"}}')[1] == 2                        # #8 nested, not an envelope
        # last json block wins test updated: fail without findings is invalid -> ambiguous
        assert rv('```json\n{"verdict":"pass"}\n```\n```json\n{"verdict":"fail"}\n```') == ("ambiguous", 2)  # fail invalid, ambiguous
        assert rv('{"verdict":"fail"} bare {"verdict":"pass"}') == ("ambiguous", 2)  # no fence + conflict -> fail closed
        assert rv('prose "{not json}" then\n```json\n{"verdict":"pass"}\n```') == ("pass", 0)  # braces in strings
        
        # Test lens coverage
        text_with_lens = '''Some prose.
```json
{"verdict":"pass","findings":[],"diagnostic":"","lens_coverage":{"redteam":true,"qa":true}}
```'''
        verdict_word, code, envelope = read_verdict_with_envelope(text_with_lens)
        assert verdict_word == "pass" and code == 0
        assert envelope is not None
        # Check lens coverage function
        missing, covered = check_lens_coverage(["redteam", "qa"], envelope)
        assert missing == [] and set(covered) == {"redteam", "qa"}
        missing, covered = check_lens_coverage(["redteam", "qa", "missing"], envelope)
        assert missing == ["missing"] and set(covered) == {"redteam", "qa"}
        
        # Test missing lens coverage
        text_missing = '''Some prose.
```json
{"verdict":"pass","findings":[],"diagnostic":""}
```'''
        verdict_word2, code2, envelope2 = read_verdict_with_envelope(text_missing)
        missing2, covered2 = check_lens_coverage(["redteam"], envelope2)
        assert missing2 == ["redteam"] and covered2 == []
        
        # Test ledger file-write behavior
        import tempfile
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as tmp:
            tmp_path = tmp.name
        
        # Override ledger path via environment variable (matching hold.py/claim-ledger.py convention)
        import os
        saved_env = os.environ.get("SM_LENS_COVERAGE_LEDGER")
        os.environ["SM_LENS_COVERAGE_LEDGER"] = tmp_path
        try:
            # Call main with --lenses to trigger ledger write
            # We'll simulate a subprocess call to test real code path
            import subprocess
            text_for_ledger = '''Some prose.
```json
{"verdict":"fail","findings":["bin/doctor.sh:322,419 something"],"diagnostic":"","lens_coverage":{"redteam":true}}
```'''
            result = subprocess.run(
                [sys.executable, __file__, "--lenses", "redteam"],
                input=text_for_ledger.encode(),
                capture_output=True,
                text=False
            )
            assert result.returncode == 1  # fail verdict
            
            # Read back the ledger file
            with open(tmp_path) as f:
                lines = f.readlines()
                assert len(lines) == 1
                import json
                record = json.loads(lines[0])
                assert record["requested"] == ["redteam"]
                assert record["covered"] == ["redteam"]
                assert record["missing"] == []
                assert record["verdict"] == "fail"
                assert "timestamp" in record
                
            # Test with missing lens
            text_missing_lens = '''Some prose.
```json
{"verdict":"pass","findings":[],"diagnostic":"","lens_coverage":{"redteam":true}}
```'''
            result2 = subprocess.run(
                [sys.executable, __file__, "--lenses", "redteam,qa"],
                input=text_missing_lens.encode(),
                capture_output=True,
                text=False
            )
            assert result2.returncode == 2  # ambiguous due to missing lens
            
            with open(tmp_path) as f:
                lines = f.readlines()
                assert len(lines) == 2
                record2 = json.loads(lines[1])
                assert record2["requested"] == ["redteam", "qa"]
                assert record2["covered"] == ["redteam"]
                assert record2["missing"] == ["qa"]
                assert record2["verdict"] == "pass"
                
        finally:
            # Clean up
            if saved_env is None:
                os.environ.pop("SM_LENS_COVERAGE_LEDGER", None)
            else:
                os.environ["SM_LENS_COVERAGE_LEDGER"] = saved_env
            import os as os_module
            if os_module.path.exists(tmp_path):
                os_module.remove(tmp_path)
            lock_path = tmp_path + ".lock"
            if os_module.path.exists(lock_path):
                os_module.remove(lock_path)
        
        print("ok")
        return
    
    # Normal operation
    text = open(args.file).read() if args.file else sys.stdin.read()
    verdict_word, exit_code, envelope = read_verdict_with_envelope(text)
    
    requested_lenses = []
    if args.lenses:
        requested_lenses = [l.strip() for l in args.lenses.split(",") if l.strip()]
    
    if requested_lenses:
        missing, covered = check_lens_coverage(requested_lenses, envelope)
        # Record to ledger regardless of outcome
        _record_lens_coverage(requested_lenses, covered, missing, verdict_word)
        # If any lens missing, result must be ambiguous (exit 2)
        if missing:
            verdict_word = "ambiguous"
            exit_code = EXIT["ambiguous"]
    
    print(verdict_word)
    sys.exit(exit_code)


if __name__ == "__main__":
    main(sys.argv[1:])