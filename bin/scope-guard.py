#!/usr/bin/env python3
# ponytail: marker lives in a fixed directory OUTSIDE the worktree tree entirely (see _marker_root),
# not an env var -- PreToolUse hooks are fresh subprocesses every call, so anything written to
# os.environ in one invocation is gone before the next one starts. A real file on disk is the only
# thing that actually persists across invocations.
"""scope-guard.py -- PreToolUse hook: confine a secondmate MAKER session to its own git worktree.

  scope-guard.py             # reads the PreToolUse JSON payload from stdin (wired via hooks.json)
  scope-guard.py selfcheck
  scope-guard.py markerpath <worktree-root>   # print where mark-maker.sh should write the marker

Real incident this defends against: a maker did ordinary-looking things -- `gh pr view`, `cat` a file it
assumed was local -- that happened to touch credentials/files outside its intended scope in a different
repo. This hook denies Bash/Read/Edit/Write/NotebookEdit calls whose resolved path(s) fall outside the
maker's own worktree, and denies Bash commands that read credential stores (macOS Keychain via `security`,
`gh auth`) unless SM_MAKER_ALLOW_CREDS=1 is explicitly set.

ACTIVATION: only when the session's cwd is inside a git worktree whose realpath has a marker file under
`_marker_root()` (default `~/.secondmate-markers`, override with SM_MARKER_ROOT), written once by
mark-maker.sh at maker-launch time (called from new-worktree.sh / herdr-pane.sh spawn -- never in the
primary checkout). No marker -> no-op, exit 0. The marker deliberately lives OUTSIDE the worktree tree
entirely, in a supervisor-controlled directory the marked session cannot reach: this hook's own
path-confinement (proven below) already denies any Bash/Edit/Write/NotebookEdit call that targets a path
outside the worktree root, so a file that lives there is protected by the same mechanism it activates --
no extra defense needed, and no reliance on an in-process env var that wouldn't survive to the next hook
invocation anyway.

FAIL-OPEN vs FAIL-CLOSED, deliberately different at two layers:
  - Can we even tell if this is a maker session (bad/missing stdin JSON, git unavailable, cwd gone)?
    Fail OPEN (allow) -- a broken hook must never brick tool calls in every OTHER session on the machine.
  - Given a CONFIRMED maker session, is a specific path/command in or out of scope?
    Fail CLOSED (deny) on anything unresolvable or ambiguous (symlink escapes, `..` traversal, unexpanded
    shell variables/substitutions in a path-looking token, unparseable quoting, command substitutions).

SCOPE OF THE BASH GUARD -- READ BEFORE RELYING ON THIS FOR ANYTHING ADVERSARIAL:
Bash commands are scanned with a token heuristic (shlex + regex), not a real shell parser and not an OS
sandbox. It is a best-effort deterrent against accidental scope creep and common evasive patterns (shell
variable indirection, command substitution, credential commands wrapped in `sh -c`, inline interpreter
one-liners, decode-into-shell pipelines) -- the concrete things a real maker session has been observed to
do or that are one obvious step away from the real incident above. It is NOT a sandboxing boundary: a
deliberately adversarial process can still defeat a string heuristic (novel encodings, obscure shells,
splitting a payload across many innocuous-looking calls, etc.), and no amount of pattern-matching closes
that gap completely. Real isolation against a genuinely adversarial process requires OS-level sandboxing
(chroot, seccomp, containers) -- explicitly out of scope for this hook. Treat every fix here as raising the
cost of accidental or unsophisticated scope violations, not as chasing a moving target of encoding tricks.
"""
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys

PATH_FIELD = {"Read": "file_path", "Edit": "file_path", "Write": "file_path", "NotebookEdit": "notebook_path"}


def _marker_root():
    """Fixed, supervisor-controlled directory the marker lives under -- never inside any worktree."""
    return os.environ.get("SM_MARKER_ROOT") or os.path.join(os.path.expanduser("~"), ".secondmate-markers")


def _marker_path_for(root):
    """root (a realpath'd worktree root) -> the marker file path for it, keyed by a hash of root.

    Hashing (rather than e.g. slugifying the path) sidesteps filename-safety entirely and guarantees
    mark-maker.sh (bash) and this module compute the identical path for the identical root.
    """
    key = hashlib.sha256(root.encode()).hexdigest()
    return os.path.join(_marker_root(), key + ".marker")


def is_maker_worktree(cwd):
    """cwd inside a git worktree with a marker on disk under _marker_root() -> realpath'd worktree root; else None.

    The marker lives OUTSIDE the worktree tree entirely (finding #1, round 2): a marked maker session's
    own Bash/Edit/Write/NotebookEdit calls are already denied by this hook's path-confinement for
    anything outside its worktree root, so a marker that lives outside the root can't be written to,
    overwritten, or deleted by the very session it gates -- no separate persistence mechanism needed,
    and unlike an env var this is a real file that survives across every fresh PreToolUse subprocess.
    """
    try:
        top = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                              capture_output=True, text=True, timeout=3)
        if top.returncode != 0 or not top.stdout.strip():
            return None
        root = os.path.realpath(top.stdout.strip())

        marker_path = _marker_path_for(root)
        if not os.path.isfile(marker_path):
            return None

        # Defensive check only: _marker_root() is fixed and never chosen to be inside a worktree, but
        # if some future misconfiguration ever placed it there, refuse rather than trust a marker that
        # the session it's supposed to gate could itself have written.
        if _within_root(os.path.realpath(marker_path), root):
            return None

        return root
    except Exception:
        return None


def _within_root(path, root):
    return path == root or path.startswith(root + os.sep)


def check_path(path_value, cwd, root):
    if not path_value:
        return False, "missing path"
    p = os.path.expanduser(path_value)
    if not p.startswith("/"):
        p = os.path.join(cwd, p)
    resolved = os.path.realpath(p)
    if _within_root(resolved, root):
        return True, ""
    return False, f"'{path_value}' resolves to {resolved}, outside the maker's worktree ({root})"


def _is_path_candidate(tok):
    if tok.startswith("/") or tok.startswith("~") or "$HOME" in tok:
        return True
    # Finding #2: also catch tokens with shell variables (even if they don't start with / or ~)
    if "$" in tok:
        return True
    # Finding #1: catch command substitutions that might resolve to paths
    if "$(" in tok or "`" in tok:
        return True
    return any(seg == ".." for seg in tok.split("/"))


def _has_unresolvable_ref(tok):
    # Finding #2: shell variables ($VAR) and command substitutions ($(...), `...`) are ambiguous
    if "$(" in tok or "`" in tok:
        return True
    for m in re.finditer(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", tok):
        if m.group(1) != "HOME":  # $HOME is the one variable we resolve ourselves below
            return True
    return False


def _resolve_token(tok, cwd):
    t = tok
    if t.startswith("~"):
        t = os.path.expanduser(t)
    if "$HOME" in t:
        t = t.replace("$HOME", os.environ.get("HOME", os.path.expanduser("~")))
    if not t.startswith("/"):
        t = os.path.join(cwd, t)
    return os.path.realpath(t)


# Credential-store commands that have no filesystem path argument for the general scan below to catch
# (macOS Keychain reads via `security`, GitHub's stored token via `gh auth`). ~/.ssh, ~/.aws etc. are
# already covered by the general path scan since they resolve outside any worktree.
def _credential_command(tokens):
    """Check for credential commands at top level AND nested in sh/bash -c wrappers (finding #3)."""
    for i, tok in enumerate(tokens):
        if tok == "security":
            return "'security' reads the macOS Keychain"
        if tok == "gh" and i + 1 < len(tokens) and tokens[i + 1] == "auth":
            return "'gh auth' reads stored GitHub credentials"
        # Finding #3: detect sh/bash -c "..." wrappers and check the nested command
        if tok in ("sh", "bash", "zsh", "env") and i + 1 < len(tokens):
            # Look for -c followed by a command string
            for j in range(i + 1, len(tokens)):
                if tokens[j] == "-c" and j + 1 < len(tokens):
                    nested_cmd = tokens[j + 1]
                    try:
                        nested_tokens = shlex.split(nested_cmd)
                        nested_cred = _credential_command(nested_tokens)
                        if nested_cred:
                            return f"{nested_cred} (nested in {tok} -c)"
                    except ValueError:
                        pass  # unparseable nested command, will be caught later
                    break
    return None


# Interpreters whose inline-code flag takes the code as its own argument (finding #2a, round 2): the
# general token scan above only looks at shell words, never at a string an interpreter will itself
# execute, so `python3 -c "open('/etc/passwd').read()"` sails through untouched otherwise.
_INTERPRETER_CODE_FLAG = {
    "python": "-c", "python3": "-c", "python2": "-c",
    "node": "-e", "nodejs": "-e",
    "ruby": "-e",
    "perl": "-e",
    "php": "-r",
}
# Path-looking substrings embedded in interpreter code: an absolute path or ~-path, stopping at the
# first shell/string-quoting character so `open('/etc/passwd')` yields '/etc/passwd', not the rest of the line.
_EMBEDDED_PATH_RE = re.compile(r"~?/[^\s'\"()]+|~[^\s'\"()]*")


def _embedded_code_violation(code, cwd, root):
    """Scan an interpreter's inline code string for out-of-worktree or ambiguous path references."""
    if not code:
        return None
    for m in _EMBEDDED_PATH_RE.finditer(code):
        tok = m.group(0)
        if _has_unresolvable_ref(tok):
            return f"ambiguous path-like token '{tok}' embedded in interpreter code (unresolved shell variable/substitution)"
        resolved = _resolve_token(tok, cwd)
        if not _within_root(resolved, root):
            return f"embedded interpreter code references '{tok}' -> resolves to {resolved}, outside the maker's worktree ({root})"
    return None


def _interpreter_inline_code_violation(tokens, cwd, root):
    """Detect `python3 -c "..."` / `node -e "..."` / etc. and scan the embedded code string (finding #2a)."""
    for i, tok in enumerate(tokens):
        flag = _INTERPRETER_CODE_FLAG.get(os.path.basename(tok))
        if not flag:
            continue
        for j in range(i + 1, len(tokens)):
            if tokens[j] == flag and j + 1 < len(tokens):
                reason = _embedded_code_violation(tokens[j + 1], cwd, root)
                if reason:
                    return reason
                break
    return None


# Decode utilities whose output, piped into a shell interpreter, we cannot inspect without decoding it
# ourselves -- so the pattern itself is denied by default rather than trying to see through it (finding #2b).
_DECODE_UTILS = {"base64", "xxd", "uudecode"}
_SHELL_INTERPRETERS = {"sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh"}


def _is_decode_segment(seg):
    if not seg:
        return False
    head = os.path.basename(seg[0])
    if head in _DECODE_UTILS:
        return True
    return head == "openssl" and "enc" in seg


def _pipeline_decode_to_shell(tokens):
    """`... | base64 -d | sh` (and xxd/uudecode/openssl enc equivalents) -- deny the pattern, not the payload."""
    segments, current = [], []
    for tok in tokens:
        if tok == "|":
            segments.append(current)
            current = []
        else:
            current.append(tok)
    segments.append(current)
    if len(segments) < 2:
        return None
    decode_idx = next((i for i, seg in enumerate(segments) if _is_decode_segment(seg)), None)
    shell_idx = next((i for i, seg in enumerate(segments)
                       if seg and os.path.basename(seg[0]) in _SHELL_INTERPRETERS), None)
    if decode_idx is not None and shell_idx is not None and decode_idx < shell_idx:
        return ("pipeline decodes data (base64/xxd/uudecode/openssl enc) into a shell interpreter -- "
                "denied by default (decoded content can't be inspected without decoding it first)")
    return None


def check_bash(command, cwd, root):
    try:
        tokens = shlex.split(command or "", comments=False)
    except ValueError:
        return False, "unparseable shell syntax (unbalanced quoting) -- ambiguous, denying"

    if os.environ.get("SM_MAKER_ALLOW_CREDS") != "1":
        cred = _credential_command(tokens)
        if cred:
            return False, f"blocked: {cred} (set SM_MAKER_ALLOW_CREDS=1 to allow)"

    pipeline_reason = _pipeline_decode_to_shell(tokens)
    if pipeline_reason:
        return False, pipeline_reason

    interp_reason = _interpreter_inline_code_violation(tokens, cwd, root)
    if interp_reason:
        return False, interp_reason

    for tok in tokens:
        if not _is_path_candidate(tok):
            continue
        if _has_unresolvable_ref(tok):
            return False, f"ambiguous path token '{tok}' (unresolved shell variable/substitution)"
        resolved = _resolve_token(tok, cwd)
        if not _within_root(resolved, root):
            return False, f"'{tok}' resolves to {resolved}, outside the maker's worktree ({root})"
    return True, ""


def decide(tool_name, tool_input, cwd, root):
    if tool_name == "Bash":
        return check_bash(tool_input.get("command", ""), cwd, root)
    field = PATH_FIELD.get(tool_name)
    if field:
        return check_path(tool_input.get(field, ""), cwd, root)
    return True, ""  # tool outside this hook's stated scope -- not restricted


def _deny(reason, tool_name):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))
    print(f"scope-guard: DENY {tool_name}: {reason}", file=sys.stderr)
    return 2


def main(argv):
    if argv[:1] == ["selfcheck"]:
        return _selfcheck()
    if argv[:1] == ["markerpath"]:
        if len(argv) < 2 or not argv[1]:
            print("usage: scope-guard.py markerpath <worktree-root>", file=sys.stderr)
            return 2
        print(_marker_path_for(os.path.realpath(argv[1])))
        return 0
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # can't even read the hook payload -- fail OPEN, see module docstring
    cwd = payload.get("cwd") or os.getcwd()
    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input") or {}
    root = is_maker_worktree(cwd)
    if root is None:
        return 0  # not a marked maker session (e.g. the supervisor's primary checkout) -- no-op
    # Finding #4: malformed input (e.g. file_path as a list) must fail CLOSED with deny JSON, not crash
    try:
        allowed, reason = decide(tool_name, tool_input, cwd, root)
    except Exception as e:
        return _deny(f"malformed tool input or path resolution error: {e}", tool_name)
    if allowed:
        return 0
    return _deny(reason, tool_name)


def _selfcheck():
    import tempfile

    fails = 0

    def check(label, cond):
        nonlocal fails
        if not cond:
            print(f"FAIL: {label}")
            fails += 1

    # --- pure decide() cases, fabricated root/cwd -----------------------------------------------
    with tempfile.TemporaryDirectory() as td:
        root = os.path.realpath(td)
        os.makedirs(os.path.join(root, "sub"), exist_ok=True)
        open(os.path.join(root, "sub", "f.txt"), "w").close()
        outside = os.path.realpath(tempfile.mkdtemp())

        check("accept: Read inside worktree",
              decide("Read", {"file_path": os.path.join(root, "sub", "f.txt")}, root, root)[0] is True)
        check("reject: Read absolute path outside worktree",
              decide("Read", {"file_path": os.path.join(outside, "secret")}, root, root)[0] is False)
        check("reject: Write via traversal escaping worktree",
              decide("Write", {"file_path": os.path.join(root, "sub", "..", "..", "escape")}, root, root)[0] is False)

        # symlink escape: a link inside the worktree pointing outside it
        link = os.path.join(root, "sub", "escape-link")
        os.symlink(outside, link)
        check("reject: Edit through a symlink that escapes the worktree",
              decide("Edit", {"file_path": os.path.join(link, "secret")}, root, root)[0] is False)

        check("reject: NotebookEdit outside worktree",
              decide("NotebookEdit", {"notebook_path": "/etc/nope.ipynb"}, root, root)[0] is False)
        check("accept: NotebookEdit inside worktree (relative)",
              decide("NotebookEdit", {"notebook_path": "sub/f.txt"}, root, root)[0] is True)

        # --- Bash cases ---
        check("accept: ordinary git/npm/test commands",
              decide("Bash", {"command": "git status && npm test -- --watch=false"}, root, root)[0] is True)
        check("accept: relative path with no traversal",
              decide("Bash", {"command": "cat sub/f.txt"}, root, root)[0] is True)
        check("reject: absolute path outside worktree",
              decide("Bash", {"command": "cat /etc/passwd"}, root, root)[0] is False)
        check("reject: traversal escaping worktree",
              decide("Bash", {"command": "cat ../../etc/passwd"}, root, root)[0] is False)
        check("reject: ambiguous var in a path-looking token",
              decide("Bash", {"command": "cat \"$SECRET_DIR/../etc/passwd\""}, root, root)[0] is False)
        check("reject: unparseable quoting",
              decide("Bash", {"command": "echo \"unterminated"}, root, root)[0] is False)

        # Finding #2: shell variable expansion bypass
        check("reject: shell variable indirection (d=/etc; cat $d/passwd)",
              decide("Bash", {"command": "d=/etc; cat $d/passwd"}, root, root)[0] is False)
        check("reject: command substitution in path position",
              decide("Bash", {"command": "cat $(echo /etc/passwd)"}, root, root)[0] is False)
        check("reject: backtick command substitution",
              decide("Bash", {"command": "cat `echo /etc/passwd`"}, root, root)[0] is False)

        # Finding #2a (round 2): inline interpreter code with an out-of-worktree path argument
        check("reject: python3 -c reading an out-of-worktree file",
              decide("Bash", {"command": "python3 -c \"print(open('/etc/passwd').read())\""}, root, root)[0] is False)
        check("reject: node -e reading an out-of-worktree file",
              decide("Bash", {"command": "node -e \"require('fs').readFileSync('/etc/passwd')\""}, root, root)[0] is False)
        check("reject: ruby -e reading an out-of-worktree file",
              decide("Bash", {"command": "ruby -e \"File.read('/etc/passwd')\""}, root, root)[0] is False)
        check("accept: python3 -c touching only in-worktree paths",
              decide("Bash", {"command": f"python3 -c \"open('{os.path.join(root, 'sub', 'f.txt')}').read()\""}, root, root)[0] is True)

        # Finding #2b (round 2): decode-utility output piped into a shell interpreter
        check("reject: base64 -d piped into sh",
              decide("Bash", {"command": "echo Y2F0IC9ldGMvcGFzc3dk | base64 -d | sh"}, root, root)[0] is False)
        check("reject: xxd -r piped into bash",
              decide("Bash", {"command": "echo deadbeef | xxd -r -p | bash"}, root, root)[0] is False)
        check("reject: openssl enc -d piped into sh",
              decide("Bash", {"command": "echo x | openssl enc -d -base64 | sh"}, root, root)[0] is False)
        check("accept: base64 -d NOT piped into a shell",
              decide("Bash", {"command": "echo Y2F0 | base64 -d"}, root, root)[0] is True)

        os.environ.pop("SM_MAKER_ALLOW_CREDS", None)
        check("reject: security (keychain) command by default",
              decide("Bash", {"command": "security find-generic-password -s x -w"}, root, root)[0] is False)
        check("reject: gh auth by default",
              decide("Bash", {"command": "gh auth token"}, root, root)[0] is False)
        # Finding #3: credential commands nested in sh/bash -c wrappers
        check("reject: security nested in sh -c",
              decide("Bash", {"command": "sh -c \"security find-generic-password -w\""}, root, root)[0] is False)
        check("reject: gh auth nested in bash -c",
              decide("Bash", {"command": "bash -c 'gh auth token'"}, root, root)[0] is False)
        check("reject: security nested in env wrapper",
              decide("Bash", {"command": "env -i sh -c 'security find-generic-password -w'"}, root, root)[0] is False)
        os.environ["SM_MAKER_ALLOW_CREDS"] = "1"
        check("accept: security command with explicit opt-in",
              decide("Bash", {"command": "security find-generic-password -s x -w"}, root, root)[0] is True)
        check("accept: nested security with explicit opt-in",
              decide("Bash", {"command": "sh -c 'security find-generic-password -w'"}, root, root)[0] is True)
        os.environ.pop("SM_MAKER_ALLOW_CREDS", None)

    # --- is_maker_worktree(): real git worktree, marker presence gates activation -----------------
    tmp = tempfile.mkdtemp()
    marker_root = os.path.join(tmp, "markers")
    prior_marker_root = os.environ.get("SM_MARKER_ROOT")
    os.environ["SM_MARKER_ROOT"] = marker_root
    try:
        proj = os.path.join(tmp, "proj")
        subprocess.run(["git", "init", "-q", "-b", "main", proj], check=True)
        subprocess.run(["git", "-C", proj, "config", "user.email", "t@t"], check=True)
        subprocess.run(["git", "-C", proj, "config", "user.name", "t"], check=True)
        with open(os.path.join(proj, "f"), "w") as f:
            f.write("x\n")
        subprocess.run(["git", "-C", proj, "add", "-A"], check=True)
        subprocess.run(["git", "-C", proj, "commit", "-qm", "init"], check=True)
        wt = os.path.join(tmp, "wt")
        subprocess.run(["git", "-C", proj, "worktree", "add", "-q", "-b", "feat", wt, "main"], check=True)
        wt_root = os.path.realpath(wt)

        check("no marker -> not a maker session (supervisor/unrelated worktree unaffected)",
              is_maker_worktree(wt) is None)

        check("CLI markerpath matches _marker_path_for",
              subprocess.run([sys.executable, os.path.abspath(__file__), "markerpath", wt_root],
                              capture_output=True, text=True, env=os.environ).stdout.strip()
              == _marker_path_for(wt_root))

        marker_path = _marker_path_for(wt_root)
        os.makedirs(os.path.dirname(marker_path), exist_ok=True)
        with open(marker_path, "w") as f:
            f.write(f"root={wt_root}\n")

        check("marker present -> maker session, root resolved",
              is_maker_worktree(wt) == wt_root)

        # Finding #1 (round 2): the marker lives OUTSIDE the worktree it guards -- by construction,
        # not by a check that could itself be bypassed.
        check("marker lives outside the worktree it guards",
              not _within_root(os.path.realpath(marker_path), wt_root))
        # ... and that means this hook's OWN path-confinement already denies the maker session from
        # writing/deleting it -- proven via decide(), not just the path-membership predicate.
        check("scope-guard denies a Write targeting the marker file's literal path",
              decide("Write", {"file_path": marker_path}, wt_root, wt_root)[0] is False)
        check("scope-guard denies a Bash rm targeting the marker file's literal path",
              decide("Bash", {"command": f"rm {marker_path}"}, wt_root, wt_root)[0] is False)

        # Finding #1 (round 2), the actual bug: the marker must survive a FRESH subprocess invocation,
        # not just reuse within one long-lived python process (which is how the previous env-var
        # "backup" passed its own selfcheck despite providing zero real protection -- PreToolUse hooks
        # are a brand-new subprocess every single call).
        def run_fresh(payload):
            return subprocess.run([sys.executable, os.path.abspath(__file__)],
                                   input=json.dumps(payload), capture_output=True, text=True, cwd=wt,
                                   env=dict(os.environ))

        r1 = run_fresh({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": "/etc/passwd"}})
        r2 = run_fresh({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": "/etc/passwd"}})
        check("marker persists across independent fresh subprocess #1",
              r1.returncode == 2 and '"permissionDecision": "deny"' in r1.stdout)
        check("marker persists across independent fresh subprocess #2 (no shared process state)",
              r2.returncode == 2 and '"permissionDecision": "deny"' in r2.stdout)

        # --- end-to-end via main()/stdin, matching new-worktree.sh's accept+reject selfcheck style ---
        run = run_fresh

        r = run({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": os.path.join(wt, "f")}})
        check("e2e accept: in-scope Read exits 0", r.returncode == 0)

        r = run({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": "/etc/passwd"}})
        check("e2e reject: out-of-scope Read exits 2", r.returncode == 2)
        check("e2e reject: deny JSON on stdout", '"permissionDecision": "deny"' in r.stdout)

        os.remove(marker_path)
        r = run({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": "/etc/passwd"}})
        check("e2e no-op: unmarked worktree exits 0 even for an out-of-scope path", r.returncode == 0)

        # Re-mark for finding #4 tests
        os.makedirs(os.path.dirname(marker_path), exist_ok=True)
        with open(marker_path, "w") as f:
            f.write(f"root={wt_root}\n")

        # Finding #4: malformed input must fail closed (exit 2 with deny JSON), not crash
        r = run({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": ["/etc/passwd"]}})
        check("e2e finding #4: file_path as list exits 2 (deny)", r.returncode == 2)
        check("e2e finding #4: file_path as list has deny JSON", '"permissionDecision": "deny"' in r.stdout)

        r = run({"cwd": wt, "tool_name": "Bash", "tool_input": {"command": 12345}})
        check("e2e finding #4: command as int exits 2 (deny)", r.returncode == 2)
        check("e2e finding #4: command as int has deny JSON", '"permissionDecision": "deny"' in r.stdout)
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)
        if prior_marker_root is None:
            os.environ.pop("SM_MARKER_ROOT", None)
        else:
            os.environ["SM_MARKER_ROOT"] = prior_marker_root

    if fails == 0:
        print("ok")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
