#!/usr/bin/env python3
# ponytail: prefer the fenced ```json envelope; else top-level {verdict} objects; fail-closed on conflict.
"""verdict.py -- read a checker's output, extract its JSON verdict envelope, branch deterministically.

  verdict.py [FILE]   # FILE or stdin = checker output; prints the verdict word
                      # exit: 0=pass  1=fail  2=error/refused/ambiguous/malformed
  verdict.py selfcheck

The checker is instructed to END with a fenced ```json {"verdict":...} block, so we prefer verdicts found
inside fenced blocks. If there are none, we fall back to scanning TOP-LEVEL {...} objects only — never nested
ones, so a stray "verdict" key buried in prose or structured data can't be mistaken for the envelope.
Conflicting verdicts fail closed (ambiguous). The supervisor branches on the exit code, not the prose.
"""
import json, re, sys

VALID = {"pass", "fail", "error", "refused"}
EXIT = {"pass": 0, "fail": 1, "error": 2, "refused": 2, "malformed": 2, "ambiguous": 2}


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


def read_verdict(text):
    # 1) prefer verdicts inside fenced code blocks (the instructed envelope format)
    verdicts = []
    for block in re.findall(r"```(?:json)?\s*\n(.*?)```", text, re.DOTALL):
        verdicts += _valid_verdicts(block)
    # 2) fall back to top-level objects anywhere in the text
    if not verdicts:
        verdicts = _valid_verdicts(text)
    if not verdicts:
        return "malformed", EXIT["malformed"]
    if len(set(verdicts)) > 1:               # conflicting envelopes -> fail closed
        return "ambiguous", EXIT["ambiguous"]
    return verdicts[-1], EXIT[verdicts[-1]]


def main(argv):
    if argv and argv[0] == "selfcheck":
        rv = read_verdict
        assert rv('x\n```json\n{"verdict":"fail","findings":["a"],"diagnostic":""}\n```\ny') == ("fail", 1)
        assert rv('```json\n{"verdict":"pass"}\n```') == ("pass", 0)
        assert rv('no json at all') == ("malformed", 2)
        assert rv('{"verdict":"bogus"}') == ("malformed", 2)
        assert rv('{"report":{"verdict":"pass"}}')[1] == 2                        # #8 nested, not an envelope
        assert rv('{"verdict":"fail"} bare {"verdict":"pass"}') == ("ambiguous", 2)  # #7 conflict -> fail closed
        assert rv('```json\n{"verdict":"fail"}\n```\n```json\n{"verdict":"pass"}\n```') == ("ambiguous", 2)
        assert rv('prose "{not json}" then\n```json\n{"verdict":"pass"}\n```') == ("pass", 0)  # braces in strings
        print("ok"); return
    text = open(argv[0]).read() if argv else sys.stdin.read()
    v, code = read_verdict(text)
    print(v)
    sys.exit(code)


if __name__ == "__main__":
    main(sys.argv[1:])
