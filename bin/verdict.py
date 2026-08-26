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
    """Yield balanced {...} spans, ignoring braces inside JSON strings."""
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


def read_verdict(text):
    found = None
    for span in _objects(text):
        try:
            obj = json.loads(span)
        except ValueError:
            continue
        if isinstance(obj, dict) and "verdict" in obj:
            found = obj  # keep the LAST one
    if found is None:
        return "malformed", EXIT["malformed"]
    v = found.get("verdict")
    if v not in VALID:
        return "malformed", EXIT["malformed"]
    return v, EXIT[v]


def main(argv):
    if argv and argv[0] == "selfcheck":
        assert read_verdict('x\n```json\n{"verdict":"fail","findings":["a"],"diagnostic":""}\n```\ny') == ("fail", 1)
        assert read_verdict('no json at all') == ("malformed", 2)
        assert read_verdict('{"verdict":"pass"} ... later {"verdict":"error"}') == ("error", 2)  # last wins
        assert read_verdict('{"verdict":"bogus"}') == ("malformed", 2)
        print("ok"); return
    text = open(argv[0]).read() if argv else sys.stdin.read()
    v, code = read_verdict(text)
    print(v)
    sys.exit(code)


if __name__ == "__main__":
    main(sys.argv[1:])
