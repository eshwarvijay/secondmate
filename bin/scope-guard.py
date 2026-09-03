#!/usr/bin/env python3
# ponytail: marker-file activation (not an env var) -- survives split panes/subshells that don't inherit exports.
"""scope-guard.py -- PreToolUse hook: confine a secondmate MAKER session to its own git worktree.

  scope-guard.py             # reads the PreToolUse JSON payload from stdin (wired via hooks.json)
  scope-guard.py selfcheck

Real incident this defends against: a maker touched credentials/unrelated files outside its intended
scope in a different repo. This hook denies Bash/Read/Edit/Write/NotebookEdit calls whose resolved path(s)
fall outside the maker's own worktree, and denies Bash commands that read credential stores (macOS Keychain
via `security`, `gh auth`) unless SM_MAKER_ALLOW_CREDS=1 is explicitly set.

ACTIVATION: only when the session's cwd is inside a git worktree carrying a `secondmate-maker.marker` file
in its per-worktree git-path (dropped by new-worktree.sh / herdr-pane.sh spawn -- never in the primary
checkout). No marker -> no-op, exit 0. This keeps the supervisor's own primary-checkout session (and any
worktree secondmate didn't create) completely unaffected; only sessions explicitly marked as a maker are
guarded, and the marker lives inside git's own admin dir so it can't be spoofed by an ordinary file drop.

FAIL-OPEN vs FAIL-CLOSED, deliberately different at two layers:
  - Can we even tell if this is a maker session (bad/missing stdin JSON, git unavailable, cwd gone)?
    Fail OPEN (allow) -- a broken hook must never brick tool calls in every OTHER session on the machine.
  - Given a CONFIRMED maker session, is a specific path/command in or out of scope?
    Fail CLOSED (deny) on anything unresolvable or ambiguous (symlink escapes, `..` traversal, unexpanded
    shell variables/substitutions in a path-looking token, unparseable quoting).

Bash commands are scanned with a token heuristic, not a real shell parser -- sufficient to catch accidental
scope creep (the incident this defends against), not a sandbox against a deliberately evasive command.
"""
import json
import os
import re
import shlex
import subprocess
import sys

MARKER_NAME = "secondmate-maker.marker"
PATH_FIELD = {"Read": "file_path", "Edit": "file_path", "Write": "file_path", "NotebookEdit": "notebook_path"}


def is_maker_worktree(cwd):
    """cwd inside a git worktree carrying the maker marker -> realpath'd worktree root; else None."""
    try:
        top = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                              capture_output=True, text=True, timeout=3)
        if top.returncode != 0 or not top.stdout.strip():
            return None
        gp = subprocess.run(["git", "-C", cwd, "rev-parse", "--git-path", MARKER_NAME],
                             capture_output=True, text=True, timeout=3)
        if gp.returncode != 0 or not gp.stdout.strip():
            return None
        if not os.path.isfile(gp.stdout.strip()):
            return None
        return os.path.realpath(top.stdout.strip())
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
    return any(seg == ".." for seg in tok.split("/"))


def _has_unresolvable_ref(tok):
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
    for i, tok in enumerate(tokens):
        if tok == "security":
            return "'security' reads the macOS Keychain"
        if tok == "gh" and i + 1 < len(tokens) and tokens[i + 1] == "auth":
            return "'gh auth' reads stored GitHub credentials"
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
    allowed, reason = decide(tool_name, tool_input, cwd, root)
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

        os.environ.pop("SM_MAKER_ALLOW_CREDS", None)
        check("reject: security (keychain) command by default",
              decide("Bash", {"command": "security find-generic-password -s x -w"}, root, root)[0] is False)
        check("reject: gh auth by default",
              decide("Bash", {"command": "gh auth token"}, root, root)[0] is False)
        os.environ["SM_MAKER_ALLOW_CREDS"] = "1"
        check("accept: security command with explicit opt-in",
              decide("Bash", {"command": "security find-generic-password -s x -w"}, root, root)[0] is True)
        os.environ.pop("SM_MAKER_ALLOW_CREDS", None)

    # --- is_maker_worktree(): real git worktree, marker presence gates activation -----------------
    tmp = tempfile.mkdtemp()
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

        check("no marker -> not a maker session (supervisor/unrelated worktree unaffected)",
              is_maker_worktree(wt) is None)

        gp = subprocess.run(["git", "-C", wt, "rev-parse", "--git-path", MARKER_NAME],
                             capture_output=True, text=True, check=True).stdout.strip()
        os.makedirs(os.path.dirname(gp), exist_ok=True)
        with open(gp, "w") as f:
            f.write("feat\n")

        check("marker present -> maker session, root resolved",
              is_maker_worktree(wt) == os.path.realpath(wt))

        # --- end-to-end via main()/stdin, matching new-worktree.sh's accept+reject selfcheck style ---
        def run(payload):
            return subprocess.run([sys.executable, os.path.abspath(__file__)],
                                   input=json.dumps(payload), capture_output=True, text=True, cwd=wt)

        r = run({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": os.path.join(wt, "f")}})
        check("e2e accept: in-scope Read exits 0", r.returncode == 0)

        r = run({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": "/etc/passwd"}})
        check("e2e reject: out-of-scope Read exits 2", r.returncode == 2)
        check("e2e reject: deny JSON on stdout", '"permissionDecision": "deny"' in r.stdout)

        os.remove(gp)
        r = run({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": "/etc/passwd"}})
        check("e2e no-op: unmarked worktree exits 0 even for an out-of-scope path", r.returncode == 0)
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

    if fails == 0:
        print("ok")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
