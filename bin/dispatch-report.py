#!/usr/bin/env python3
# ponytail: three anchored line-prefix tags, last line wins, plain sys.argv -- no argparse, no classes.
"""dispatch-report.py -- read a sub-supervisor's final output, extract its completion tag, branch
deterministically. Third primitive toward a multi-supervisor dispatch loop (see SKILL.md's fan-out
section): each sub-supervisor launched by a top-level dispatcher emits exactly ONE completion tag, on
its own line, as its literal final output. This script is how the dispatcher turns that prose into an
exit code instead of re-reading it to make its own judgment call.

  dispatch-report.py [FILE]   # FILE or stdin = sub-supervisor's final text; prints the matched tag line
                              # exit: 0=SM_DONE_MERGED  1=SM_REFUSED  2=SM_STUCK_NEED_HUMAN  3=no tag found
  dispatch-report.py selfcheck

Tags are recognized ONLY at the start of a line (`^`, re.MULTILINE) -- a tag substring embedded mid-line
in prose (e.g. a sub-supervisor's own prompt/instructions being echoed back, which could quote an example
of the tag it was told to emit) must not match. If more than one real tag-line appears anywhere in the
text, the LAST one wins -- the same "last block wins" precedent as verdict.py's own fenced-JSON handling,
for the same reason: an earlier line quoting an instruction is not the real signal, whatever appears last is.

Exit code 3 (no tag found at all) is deliberately its own distinct code, MORE cautious than even
SM_STUCK_NEED_HUMAN (2), because it means this parser cannot tell what happened at all -- not even a
self-reported "I'm stuck". The dispatcher must treat exit 3 as an escalation-worthy parse failure, not
assume anything about the sub-supervisor's actual state.
"""
import re, sys

_TAG_RE = re.compile(r"^(SM_DONE_MERGED|SM_STUCK_NEED_HUMAN|SM_REFUSED):(.+)$", re.MULTILINE)
EXIT = {"SM_DONE_MERGED": 0, "SM_REFUSED": 1, "SM_STUCK_NEED_HUMAN": 2}


def read_report(text):
    matches = list(_TAG_RE.finditer(text))
    if not matches:
        return "malformed", 3
    m = matches[-1]  # last matching line wins, regardless of which of the 3 tags it is
    return m.group(0), EXIT[m.group(1)]


def main(argv):
    if argv and argv[0] == "selfcheck":
        rr = read_report
        # each of the 3 real tags in isolation, realistic payload
        assert rr("SM_DONE_MERGED:1a2b3c4d\n") == ("SM_DONE_MERGED:1a2b3c4d", 0)
        assert rr("SM_REFUSED:claim-failed\n") == ("SM_REFUSED:claim-failed", 1)
        assert rr("SM_STUCK_NEED_HUMAN:checker keeps flip-flopping\n") == ("SM_STUCK_NEED_HUMAN:checker keeps flip-flopping", 2)
        # payload containing colons/slashes (a real sha, a punctuated reason) must not be truncated
        assert rr("SM_DONE_MERGED:1a2b3c4d5e6f7890abcdef1234567890abcdef12\n") == \
            ("SM_DONE_MERGED:1a2b3c4d5e6f7890abcdef1234567890abcdef12", 0)
        assert rr("SM_REFUSED:cannot merge: conflict in path/to/file.py\n") == \
            ("SM_REFUSED:cannot merge: conflict in path/to/file.py", 1)
        # multiple different tags in one text -> the LAST one wins (direct analog of verdict.py's
        # own "last json block wins" test)
        assert rr("SM_REFUSED:first-attempt\nSM_DONE_MERGED:deadbeef\n") == ("SM_DONE_MERGED:deadbeef", 0)
        assert rr("SM_DONE_MERGED:deadbeef\nSM_STUCK_NEED_HUMAN:changed my mind\n") == \
            ("SM_STUCK_NEED_HUMAN:changed my mind", 2)
        # no tag at all -> malformed, exit 3
        assert rr("just some prose with no completion tag anywhere") == ("malformed", 3)
        # a tag pattern embedded mid-line / in prose (not at start-of-line) must NOT match -- direct
        # analog of verdict.py's "#3 example ignored" / "#8 nested, not an envelope" tests
        assert rr("The prompt told it to emit SM_DONE_MERGED:abc123 as its final line.") == ("malformed", 3)
        # mid-line echo of an instruction, followed by the REAL tag on its own line -> the real
        # (last, start-of-line) tag wins; the embedded example is ignored, not mistaken for the signal
        assert rr("Your instructions said to end with SM_STUCK_NEED_HUMAN:example-only if stuck.\n"
                   "SM_DONE_MERGED:cafebabe\n") == ("SM_DONE_MERGED:cafebabe", 0)
        print("ok"); return
    text = open(argv[0]).read() if argv else sys.stdin.read()
    v, code = read_report(text)
    print(v)
    sys.exit(code)


if __name__ == "__main__":
    main(sys.argv[1:])
