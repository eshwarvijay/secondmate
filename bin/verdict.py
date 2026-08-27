#!/usr/bin/env python3
# ponytail: brace-scan + json.loads — no jq dependency, no schema lib.
"""verdict.py -- read a checker's output, extract its JSON verdict envelope, branch deterministically.

  verdict.py [FILE]   # FILE or stdin = checker output; prints the verdict word
                      # exit: 0=pass  1=fail  2=error/refused/malformed
  verdict.py selfcheck

Envelope = the LAST balanced {...} that parses and has a "verdict" key:
  {"verdict":"pass|fail|error|refused","findings":["..."],"diagnostic":"..."}
The supervisor branches on the exit code instead of grepping the checker's prose.
"""
import json, sys

VALID = {"pass", "fail", "error", "refused"}
EXIT = {"pass": 0, "fail": 1, "error": 2, "refused": 2, "malformed": 2}


def _objects(text):
    """Yield (end_index, span) for EVERY balanced {...} at any nesting depth, ignoring braces in strings.
    Yielding nested spans too (not just top-level) is what lets us find the real envelope inside e.g.
    `{{"verdict":"fail"}}` (finding #13)."""
    stack = []; in_str = False; esc = False
    for i, c in enumerate(text):
        if in_str:
            if esc: esc = False
            elif c == "\\": esc = True
            elif c == '"': in_str = False
            continue
        if c == '"': in_str = True
        elif c == "{": stack.append(i)
        elif c == "}" and stack:
            start = stack.pop()
            yield i, text[start:i + 1]


def read_verdict(text):
    # Pick the LAST-closing balanced object that parses AND carries a valid verdict. A bogus/template
    # "verdict" value elsewhere is skipped rather than poisoning a real envelope.
    best = None; best_end = -1
    for end, span in _objects(text):
        try:
            obj = json.loads(span)
        except ValueError:
            continue
        if isinstance(obj, dict) and obj.get("verdict") in VALID and end > best_end:
            best_end = end; best = obj
    if best is None:
        return "malformed", EXIT["malformed"]
    v = best["verdict"]
    return v, EXIT[v]


def main(argv):
    if argv and argv[0] == "selfcheck":
        assert read_verdict('x\n```json\n{"verdict":"fail","findings":["a"],"diagnostic":""}\n```\ny') == ("fail", 1)
        assert read_verdict('no json at all') == ("malformed", 2)
        assert read_verdict('{"verdict":"pass"} ... later {"verdict":"error"}') == ("error", 2)  # last wins
        assert read_verdict('{"verdict":"bogus"}') == ("malformed", 2)
        assert read_verdict('{"verdict":"pass"} prose {{"verdict":"fail"}}') == ("fail", 1)  # #13 nested
        assert read_verdict('note "{not json}" then {"verdict":"pass"}') == ("pass", 0)      # braces in strings
        assert read_verdict('{"verdict":"pass|fail|error|refused"} then {"verdict":"fail"}') == ("fail", 1)  # template skipped
        print("ok"); return
    text = open(argv[0]).read() if argv else sys.stdin.read()
    v, code = read_verdict(text)
    print(v)
    sys.exit(code)


if __name__ == "__main__":
    main(sys.argv[1:])
