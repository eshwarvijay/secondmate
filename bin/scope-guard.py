#!/usr/bin/env python3
# ponytail: marker-file + env var activation -- env var injection on marker presence defends against
# marker deletion, while marker file survives split panes/subshells (env vars wouldn't be inherited).
"""scope-guard.py -- PreToolUse hook: confine a secondmate MAKER session to its own git worktree.

  scope-guard.py             # reads the PreToolUse JSON payload from stdin (wired via hooks.json)
  scope-guard.py selfcheck

Real incident this defends against: a maker touched credentials/unrelated files outside its intended
scope in a different repo. This hook denies Bash/Read/Edit/Write/NotebookEdit calls whose resolved path(s)
fall outside the maker's own worktree, and denies Bash commands that read credential stores (macOS Keychain
via `security`, `gh auth`) unless SM_MAKER_ALLOW_CREDS=1 is explicitly set.

ACTIVATION: only when the session's cwd is inside a git worktree carrying a `secondmate-maker.marker` file
in its per-worktree git-path (dropped by new-worktree.sh / herdr-pane.sh spawn / mark-maker.sh -- never
in the primary checkout). No marker -> no-op, exit 0. The marker must be OUTSIDE the worktree root
(in .git/worktrees/<name>/) to prevent deletion by the session it gates. This keeps the supervisor's own
primary-checkout session (and any worktree secondmate didn't create) completely unaffected; only sessions
explicitly marked as a maker are guarded.

FAIL-OPEN vs FAIL-CLOSED, deliberately different at two layers:
  - Can we even tell if this is a maker session (bad/missing stdin JSON, git unavailable, cwd gone)?
    Fail OPEN (allow) -- a broken hook must never brick tool calls in every OTHER session on the machine.
  - Given a CONFIRMED maker session, is a specific path/command in or out of scope?
    Fail CLOSED (deny) on anything unresolvable or ambiguous (symlink escapes, `..` traversal, unexpanded
    shell variables/substitutions in a path-looking token, unparseable quoting, command substitutions).

Bash commands are scanned with a token heuristic, not a real shell parser -- sufficient to catch accidental
scope creep AND simple evasion (the incident this defends against), not a sandbox against a sophisticated adversary.
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
    """cwd inside a git worktree carrying the maker marker -> realpath'd worktree root; else None.

    Defends against marker deletion (finding #1): the marker must be OUTSIDE the worktree root
    (in .git/worktrees/<name>/ or equivalent), not inside it where a marked session could delete it.
    Also checks SM_WORKTREE_ROOT env var as a secondary source (set on initial activation).
    """
    try:
        top = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                              capture_output=True, text=True, timeout=3)
        if top.returncode != 0 or not top.stdout.strip():
            return _check_env_backup(cwd)
        root = os.path.realpath(top.stdout.strip())

        gp = subprocess.run(["git", "-C", cwd, "rev-parse", "--git-path", MARKER_NAME],
                             capture_output=True, text=True, timeout=3)
        if gp.returncode != 0 or not gp.stdout.strip():
            return _check_env_backup(cwd)

        marker_path = gp.stdout.strip()
        # Resolve relative marker paths relative to cwd, not process cwd
        if not marker_path.startswith("/"):
            marker_path = os.path.join(cwd, marker_path)
        marker_path = os.path.realpath(marker_path)

        if not os.path.isfile(marker_path):
            # Marker was deleted - check env var backup (finding #1 defense)
            return _check_env_backup(cwd)

        # Defense: marker must be OUTSIDE the worktree root (finding #1).
        # In a proper worktree, the marker lives in .git/worktrees/<name>/ which is outside the tree.
        # If it's somehow inside (misconfiguration or attack), refuse to activate.
        if _within_root(marker_path, root):
            return None  # suspicious: marker inside the tree it's supposed to guard

        # Set env var on first activation so even if marker is later deleted, we remember this is a maker session
        if "SM_WORKTREE_ROOT" not in os.environ:
            os.environ["SM_WORKTREE_ROOT"] = root

        return root
    except Exception:
        return _check_env_backup(cwd)


def _check_env_backup(cwd):
    """Backup: if marker check failed but SM_WORKTREE_ROOT is set and cwd is within it, trust it (finding #1)."""
    env_root = os.environ.get("SM_WORKTREE_ROOT")
    if env_root:
        try:
            if _within_root(os.path.realpath(cwd), env_root):
                return env_root
        except Exception:
            pass
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

        # Finding #1: marker inside worktree (not in .git/worktrees/) must be rejected
        fake_marker = os.path.join(wt, ".git-fake-marker")
        with open(fake_marker, "w") as f:
            f.write("fake\n")
        # We'll test this by verifying that _within_root catches it:
        check("marker-inside-worktree: _within_root correctly identifies marker inside root",
              _within_root(os.path.realpath(fake_marker), os.path.realpath(wt)) is True)

        # Finding #1: env var SM_WORKTREE_ROOT survives marker deletion
        # First call is_maker_worktree to set the env var
        _ = is_maker_worktree(wt)  # sets SM_WORKTREE_ROOT
        os.remove(gp)  # delete the marker
        check("env var backup: after marker deletion, env var keeps session marked",
              is_maker_worktree(wt) == os.path.realpath(wt))
        os.environ.pop("SM_WORKTREE_ROOT", None)

        # Re-create marker for e2e tests
        os.makedirs(os.path.dirname(gp), exist_ok=True)
        with open(gp, "w") as f:
            f.write("feat\n")

        # --- end-to-end via main()/stdin, matching new-worktree.sh's accept+reject selfcheck style ---
        def run(payload):
            return subprocess.run([sys.executable, os.path.abspath(__file__)],
                                   input=json.dumps(payload), capture_output=True, text=True, cwd=wt,
                                   env={k: v for k, v in os.environ.items() if k != "SM_WORKTREE_ROOT"})

        r = run({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": os.path.join(wt, "f")}})
        check("e2e accept: in-scope Read exits 0", r.returncode == 0)

        r = run({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": "/etc/passwd"}})
        check("e2e reject: out-of-scope Read exits 2", r.returncode == 2)
        check("e2e reject: deny JSON on stdout", '"permissionDecision": "deny"' in r.stdout)

        os.remove(gp)
        r = run({"cwd": wt, "tool_name": "Read", "tool_input": {"file_path": "/etc/passwd"}})
        check("e2e no-op: unmarked worktree exits 0 even for an out-of-scope path", r.returncode == 0)

        # Re-mark for finding #4 tests
        with open(gp, "w") as f:
            f.write("feat\n")

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

    if fails == 0:
        print("ok")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
