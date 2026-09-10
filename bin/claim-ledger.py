#!/usr/bin/env python3
# ponytail: append-only JSONL ledger, fcntl-locked -- same idiom as hold.py. No sqlite, no heartbeats,
# no compaction: this is a human-supervised batch tool, not a system processing thousands of tasks.
"""claim-ledger.py -- atomic task-id claims so concurrently-running sub-agent-supervisors (each in its own
git worktree) never work the same task at once.

  claim-ledger.py claim   --task-id ID --owner LABEL                        -> claims ID iff no open claim
                                                                                exists; prints a --token the
                                                                                caller must save to release it
  claim-ledger.py release --task-id ID --owner LABEL --token TOK            -> closes ID's open claim, but
                                                                                ONLY if both --owner AND
                                                                                --token match the open claim
  claim-ledger.py steal   --task-id ID --owner LABEL --reason TXT           -> human-supervised override:
                                                                                unconditionally closes whatever
                                                                                is open on ID (if anything) and
                                                                                reopens it under LABEL; no
                                                                                --token required to perform the
                                                                                steal itself (it's the escape
                                                                                hatch), but the new claim it
                                                                                opens gets its own fresh token
  claim-ledger.py status | list                                            -> lists all currently-open claims
                                                                                (owner/claimed_at -- never a token)
  claim-ledger.py selfcheck                                                -> asserts the fold + drives the
                                                                                real CLI paths

Ledger path resolution (first match wins):
  1. $SM_CLAIM_LEDGER, if set -- used exactly as given.
  2. $SM_LOOP_STATE/claims.jsonl, if $SM_LOOP_STATE is set.
  3. Otherwise, anchored to `git rev-parse --git-common-dir` (the one physical location every worktree of
     the same repo -- including the primary checkout -- agrees on; same mechanism bin/mark-maker.sh uses
     to distinguish primary vs. linked worktrees). Anchored at that common-dir's PARENT only when the
     common-dir's own basename is literally `.git` -- the normal case (a primary checkout's or linked
     worktree's shared .git directory). Anchored AT the common-dir itself in every OTHER case: a BARE
     repo (`--git-common-dir` resolves to '.', i.e. the bare repo's own directory, under some other
     basename) or a SUBMODULE (`--git-common-dir` resolves to something like '.git/modules/<name>' --
     basename is the submodule's own name, not '.git') -- otherwise two unrelated bare repos, or two
     submodules of the same superproject, would collide on the same arbitrary parent directory. This
     matters because every herdr-launched sub-agent-supervisor runs with its CWD set to its OWN linked
     worktree: a plain CWD-relative default would give each one an unshared ledger, defeating the entire
     point of this script. Falls back to a CWD-relative `.secondmate/claims.jsonl` (with a loud stderr
     warning) only if not inside a git repo at all.

Claim key is task-id -- this repo's convention is one task-id : one worktree : one branch (sm/<task-id>),
so task-id is the natural claim key. NOT a worktree path, NOT a PID.

No liveness/heartbeat/TTL/lease logic here, ever. This script is a collision-prevention bookkeeping layer,
not a liveness oracle -- it has no reliable way to check liveness for whichever runtime is calling it (a raw
OS PID means nothing for an Agent-tool background agent, for instance). Each real sub-agent runtime already
has its own liveness mechanism (`herdr agent get <name>`, Agent-tool completion events). The reclaim path is
`steal`, which is a mandatory-reason, human-supervised override -- the CALLER (a dispatch loop) is
responsible for checking real liveness via whatever mechanism fits its runtime BEFORE ever invoking --steal.

Ownership on `release` is enforced with a real, unguessable secret (a `secrets.token_hex(16)` minted by
`claim`/`steal` and printed once), not just a caller-supplied --owner label a bug or a mislabeled caller
could trivially repeat -- --owner alone is kept only as a human-readable double-check, not the real gate.
"""
import json, sys, os, time, re, secrets, subprocess, argparse, pathlib, contextlib, io, tempfile, shutil
try:
    import fcntl
except ImportError:  # non-Unix (e.g. Windows) -> best-effort, no locking
    fcntl = None

_SCRIPT_PATH = os.path.abspath(__file__)


def _default_ledger_path():
    """Resolve the ledger path when SM_CLAIM_LEDGER and SM_LOOP_STATE are both unset. Anchoring to plain
    CWD would defeat the entire point of this script: every herdr-launched sub-agent-supervisor runs with
    its CWD set to its OWN linked worktree, so two supervisors working the same repo would each get a
    different, unshared claims.jsonl and both 'succeed' at claiming the same task-id. `git rev-parse
    --git-common-dir` resolves to the ONE shared .git dir for the primary checkout AND every one of its
    linked worktrees (same primary-vs-worktree mechanism bin/mark-maker.sh uses) -- its parent is the one
    physical location every worktree of this repo agrees on, regardless of which one is the caller's CWD."""
    if os.environ.get("SM_CLAIM_LEDGER"):
        return pathlib.Path(os.environ["SM_CLAIM_LEDGER"])
    if os.environ.get("SM_LOOP_STATE"):
        return pathlib.Path(os.environ["SM_LOOP_STATE"]) / "claims.jsonl"
    try:
        out = subprocess.run(["git", "rev-parse", "--git-common-dir"], capture_output=True, text=True)
        if out.returncode == 0 and out.stdout.strip():
            common_dir = pathlib.Path(out.stdout.strip())
            if not common_dir.is_absolute():
                common_dir = pathlib.Path.cwd() / common_dir
            common_dir = common_dir.resolve()
            # Only take common_dir's PARENT when its own basename is literally '.git' -- the normal
            # case: a primary checkout's or linked worktree's shared .git directory, whose PARENT is
            # the one location every worktree of that repo agrees on. In every other case, anchor AT
            # common_dir itself instead:
            #   - a BARE repo: --git-common-dir resolves to '.', i.e. the bare repo's own directory,
            #     under some OTHER basename (the repo's own name) -- taking its parent would land
            #     outside the bare repo entirely, colliding with any unrelated sibling bare repo.
            #   - a SUBMODULE: --git-common-dir resolves to something like '.git/modules/<name>' --
            #     basename is the submodule's own name, not '.git'; taking its parent ('.git/modules/')
            #     would collide with every OTHER submodule of the same superproject.
            # One basename check covers both, with no extra `--is-bare-repository` subprocess call.
            anchor = common_dir if common_dir.name != ".git" else common_dir.parent
            return anchor / ".secondmate" / "claims.jsonl"
    except OSError:
        pass  # git not installed/found -- fall through to the loud-warning CWD-relative fallback below
    sys.stderr.write(
        "WARNING: claim-ledger.py could not resolve a git-common-dir (not inside a git repo, or git not "
        "found) -- falling back to a CWD-relative ./.secondmate/claims.jsonl, which will NOT be shared "
        "across other worktrees/CWDs. Set SM_CLAIM_LEDGER to a shared path for real cross-worktree "
        "collision prevention.\n")
    return pathlib.Path(".secondmate") / "claims.jsonl"


LEDGER = _default_ledger_path()
_BAD = 0  # count of malformed/incomplete ledger lines seen by the last _recs()

# task-id must be a safe bare identifier: no path separators, no null bytes, no empty string, bounded
# length -- mirrors the defensive posture in plan-committee.sh's _claim_task_marker (path-traversal /
# symlink / self-name-matching bugs found and fixed there earlier this session).
_TASK_ID_RE = re.compile(r"\A[A-Za-z0-9_-]{1,128}\Z")

# every REAL token is minted via secrets.token_hex(16) -- a 32-character lowercase hex string. A
# claimed/stolen record whose token doesn't match this exact shape (e.g. a NUL byte, which IS a
# non-empty string but which no real CLI could ever supply back as a --token argv value) is just as
# unwedgeable as a missing token, so it must be treated the same way: malformed, not a valid open claim.
_TOKEN_RE = re.compile(r"\A[0-9a-f]{32}\Z")


def _valid_task_id(task_id):
    return isinstance(task_id, str) and bool(_TASK_ID_RE.match(task_id))


def _recs():
    # tolerant parse: skip malformed/incomplete lines but COUNT them (same discipline as hold.py), so
    # `status` warns instead of a partial write silently hiding an open claim.
    global _BAD
    _BAD = 0
    recs = []
    if not LEDGER.exists():
        return recs
    for line in LEDGER.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except ValueError:
            _BAD += 1; continue
        ev = o.get("ev") if isinstance(o, dict) else None
        valid = (isinstance(o, dict) and ev in ("claimed", "released", "stolen")
                 and isinstance(o.get("task_id"), str) and isinstance(o.get("owner"), str))
        if valid and ev in ("claimed", "stolen"):
            # A tokenless (or non-token-shaped) claimed/stolen record can never be released -- no real
            # CLI can supply a --token that equals a missing field OR an un-argv-able value like an
            # embedded NUL byte -- it would permanently wedge that task-id open except through --steal.
            # Treat it as malformed/incomplete, exactly like any other broken line, instead of a valid
            # open claim. Require the EXACT secrets.token_hex(16) shape, not just "non-empty string".
            token = o.get("token")
            valid = isinstance(token, str) and bool(_TOKEN_RE.match(token))
        if valid:
            recs.append(o)
        else:
            _BAD += 1
    return recs


def _append(rec):
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    with LEDGER.open("a") as f:
        f.write(json.dumps(rec) + "\n")


@contextlib.contextmanager
def _ledger_lock():
    # Same fcntl idiom as hold.py's _ledger_lock(): serialize concurrent mutations (the read-check-append
    # in claim/release/steal) with an exclusive OS lock on a sibling .lock file.
    if fcntl is None:
        yield; return
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    with open(str(LEDGER) + ".lock", "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def open_claims(recs=None):
    """Fold the ledger to {task_id: currently-open claim record}. This is THE ONE fold primitive that
    both `status` and `steal` use -- steal re-folds fresh, inside the lock, immediately before deciding,
    never trusting an earlier separately-fetched status call (closes the TOCTOU class the committee flagged)."""
    recs = _recs() if recs is None else recs
    open_by_task = {}
    for r in recs:
        if r["ev"] in ("claimed", "stolen"):
            open_by_task[r["task_id"]] = r
        elif r["ev"] == "released":
            open_by_task.pop(r["task_id"], None)
    return open_by_task


def _run(argv):
    # selfcheck helper: invoke the REAL main() (real argparse, real claim/release/steal/status code
    # paths, real _ledger_lock/_recs/_append/open_claims) and capture the result, instead of
    # reimplementing any of this script's own logic.
    out = io.StringIO()
    code = 0
    exc = None
    try:
        with contextlib.redirect_stdout(out):
            main(argv)
    except SystemExit as e:
        code = 1
        exc = e.code
    return code, out.getvalue().strip(), exc


def _token_from_output(out):
    # both claim's and steal's success message end in 'token=<hex>' -- pull it out for a subsequent
    # release call, exactly as a real caller would have to save it from the CLI's own printed output.
    for tok in out.split():
        if tok.startswith("token="):
            return tok[len("token="):]
    return None


def _selfcheck_live():
    # Runs the *actual* CLI paths (main -> claim/release/steal/status) against a scratch ledger in a
    # temp dir, so this selfcheck would fail if the real ownership check / TOCTOU-safe steal fold /
    # task-id validation were ever broken -- not a parallel reimplementation of that logic.
    global LEDGER
    orig_ledger = LEDGER
    tmpdir = tempfile.mkdtemp(prefix="claim-ledger-selfcheck-")
    LEDGER = pathlib.Path(tmpdir) / "claims.jsonl"
    try:
        # basic claim -> visible in status -> release -> gone from status.
        code, out, _ = _run(["claim", "--task-id", "t1", "--owner", "agent-a"])
        assert code == 0, "first claim on an unclaimed task-id should succeed"
        tok_a = _token_from_output(out)
        assert tok_a, "claim must print a token the caller can later use to release"
        code, out, _ = _run(["status"])
        assert code == 0 and "t1" in out and "agent-a" in out, "status must show the open claim"
        assert tok_a not in out, "status must NEVER print the claim token"

        # collision: a different owner claiming an already-open task-id must fail, and append nothing.
        pre_len = len(_recs())
        code, _, exc = _run(["claim", "--task-id", "t1", "--owner", "agent-b"])
        assert code != 0, "claiming an already-open task-id must fail"
        assert len(_recs()) == pre_len, "a rejected claim must not append any record"

        # settled decision #3: claim is NOT idempotent, even for the SAME owner re-claiming.
        code, _, exc = _run(["claim", "--task-id", "t1", "--owner", "agent-a"])
        assert code != 0, "re-claiming an already-open task-id must fail even for the same owner"

        # ownership check on release: a different owner's release must be rejected (IDOR-style guard),
        # even if they happen to supply SOME token (they can't know the real one).
        pre_len = len(_recs())
        code, _, exc = _run(["release", "--task-id", "t1", "--owner", "agent-b", "--token", "guessed-or-irrelevant"])
        assert code != 0, "release by a non-owning owner must be rejected"
        assert "agent-b" not in str(exc) or "agent-a" in str(exc), "rejection should name the real owner"
        assert len(_recs()) == pre_len, "a rejected release must not append any record"
        assert "t1" in open_claims(), "claim must stay open after a rejected release"

        # token check on release: the CORRECT --owner with a WRONG (or missing) --token must be
        # rejected exactly like a wrong-owner attempt -- a repeated/guessed owner label alone must not
        # be enough to release someone else's claim.
        pre_len = len(_recs())
        code, _, exc = _run(["release", "--task-id", "t1", "--owner", "agent-a", "--token", "not-the-real-token"])
        assert code != 0, "release with the right owner but the WRONG token must be rejected"
        assert len(_recs()) == pre_len, "a token-mismatched release must not append any record"
        assert "t1" in open_claims(), "claim must stay open after a token-mismatched release"
        assert tok_a not in str(exc), "the rejection must not leak the real token"

        # release by the true owner WITH the correct token succeeds, and the task-id becomes claimable
        # again.
        code, _, _ = _run(["release", "--task-id", "t1", "--owner", "agent-a", "--token", tok_a])
        assert code == 0, "release by the true owner with the correct token must succeed"
        assert "t1" not in open_claims(), "released task-id must not show as open"
        code, out, _ = _run(["claim", "--task-id", "t1", "--owner", "agent-c"])
        assert code == 0, "a released task-id must be claimable again by anyone"
        tok_c = _token_from_output(out)

        # release with no open claim at all must fail cleanly.
        code, _, _ = _run(["release", "--task-id", "t1", "--owner", "agent-c", "--token", tok_c])
        assert code == 0
        code, _, _ = _run(["release", "--task-id", "t1", "--owner", "agent-c", "--token", tok_c])
        assert code != 0, "releasing a task-id with no open claim must fail"

        # steal requires a non-empty --reason.
        code, _, exc = _run(["steal", "--task-id", "t1", "--owner", "agent-d", "--reason", "   "])
        assert code != 0, "steal with a blank --reason must be rejected"

        # steal on a task-id with NO current open claim still works, and its event type is 'stolen'
        # (distinct from 'claimed'), for an honest audit trail.
        code, _, _ = _run(["steal", "--task-id", "t1", "--owner", "agent-d", "--reason", "human override, agent-c stalled"])
        assert code == 0
        stolen_recs = [r for r in _recs() if r["ev"] == "stolen" and r["task_id"] == "t1"]
        assert stolen_recs and stolen_recs[-1]["owner"] == "agent-d", "steal must record a distinct 'stolen' event"
        assert "reason" in stolen_recs[-1] and stolen_recs[-1]["reason"].strip(), "stolen record must carry the reason"

        # steal unconditionally closes whatever was open (even mid-claim by yet another owner) and
        # reopens under the new owner.
        code, _, _ = _run(["claim", "--task-id", "t2", "--owner", "agent-e"])
        assert code == 0
        code, _, _ = _run(["steal", "--task-id", "t2", "--owner", "agent-f", "--reason", "reclaim stalled task"])
        assert code == 0
        opened = open_claims()
        assert opened["t2"]["owner"] == "agent-f", "steal must reopen the task-id under the new owner"

        # TOCTOU guard, forced via a GENUINE concurrent race (not a pre-written ledger line the steal
        # call then just reads normally -- that proves nothing, since nothing else is running while it
        # reads). A background thread performs a full COMPETING steal on the same task-id, released the
        # instant our own fold call returns, so its window to run lands exactly in the gap between our
        # fold and our lock acquisition -- the real defect being guarded against. If steal ever folds
        # BEFORE acquiring the lock again, the competitor can complete during that gap and our own
        # recorded previous_owner will be stale; if steal folds INSIDE the lock (the fix), the
        # competitor blocks on the same fcntl lock and cannot run until we're done.
        import threading
        _append({"ev": "claimed", "task_id": "race", "owner": "agent-a", "token": secrets.token_hex(16),
                 "ts": time.strftime("%Y-%m-%dT%H:%M:%S")})
        real_open_claims = open_claims
        race_started = threading.Event()

        def _slow_open_claims(recs=None):
            result = real_open_claims(recs)
            if "race" in result and not race_started.is_set():
                race_started.set()  # let the competitor go, then hold this result open for a window
                time.sleep(0.3)
            return result

        def _competitor():
            race_started.wait(timeout=2)
            # NOTE: deliberately NOT wrapped in contextlib.redirect_stdout here -- that context manager
            # mutates a single global (sys.stdout) via save/restore, which is not safe to enter/exit
            # concurrently from two threads at once (it can leave sys.stdout pointing at a stale,
            # already-thrown-away StringIO after both threads finish). A little print noise on real
            # stdout during selfcheck is harmless; a silently corrupted sys.stdout is not.
            main(["steal", "--task-id", "race", "--owner", "concurrent-winner", "--reason", "racing steal"])

        t = threading.Thread(target=_competitor)
        t.start()
        globals()["open_claims"] = _slow_open_claims
        try:
            code, _, _ = _run(["steal", "--task-id", "race", "--owner", "victim-thief", "--reason", "toctou race"])
        finally:
            globals()["open_claims"] = real_open_claims
        t.join(timeout=5)
        assert not t.is_alive(), "competitor steal thread never finished -- test setup broken"
        assert code == 0

        # Ledger append order under the fcntl lock IS the true chronological order (ts has only
        # 1-second resolution, so it can't be trusted to order these two). Every 'stolen' record's
        # previous_owner must match the owner of whichever record truly precedes it in ledger order.
        race_recs = [r for r in _recs() if r["task_id"] == "race" and r["ev"] in ("claimed", "stolen")]
        assert len(race_recs) == 3, "expected exactly claimed + 2 stolen records for 'race'"
        for i in range(1, len(race_recs)):
            if race_recs[i]["ev"] == "stolen" and "previous_owner" in race_recs[i]:
                assert race_recs[i]["previous_owner"] == race_recs[i - 1]["owner"], (
                    f"stolen record claims previous_owner={race_recs[i]['previous_owner']!r} but the ledger's "
                    f"true immediately-preceding owner was {race_recs[i - 1]['owner']!r} -- steal must fold "
                    f"the ledger fresh INSIDE the lock, not from a stale pre-lock snapshot")

        # task-id validation: empty, path separators, null bytes, bad chars, embedded newline (Bug C:
        # regex '$' matches just before a trailing \n, not only true end-of-string), and over-length
        # must all fail.
        for bad in ("", "../etc", "a/b", "a\0b", "bad id", "*", "a" * 129, "ok\n"):
            code, _, _ = _run(["claim", "--task-id", bad, "--owner", "agent-x"])
            assert code != 0, f"invalid task-id {bad!r} must be rejected"

        # status must warn (not silently hide) when the ledger has malformed lines.
        with LEDGER.open("a") as f:
            f.write("not json at all\n")
        code, out, _ = _run(["status"])
        assert code == 0 and "malformed" in out.lower(), "status must surface malformed-line corruption"

        # Bug B regression: a tokenless 'claimed' record (e.g. a leftover/malformed/hand-edited ledger
        # line predating the token requirement) must be treated as malformed/incomplete -- NOT as a
        # valid open claim, since no caller could ever supply a token equal to a missing field, which
        # would permanently wedge the task-id except through --steal.
        bad_before = _BAD
        with LEDGER.open("a") as f:
            f.write(json.dumps({"ev": "claimed", "task_id": "tokenless", "owner": "agent-z",
                                 "ts": time.strftime("%Y-%m-%dT%H:%M:%S")}) + "\n")
        assert "tokenless" not in open_claims(), "a tokenless claimed record must NOT fold into an open claim"
        code, out, _ = _run(["status"])
        assert code == 0 and "tokenless" not in out, "status must not show a tokenless record as open"
        _recs()  # refresh _BAD as a side effect
        assert _BAD > bad_before, "a tokenless claimed record must be counted as malformed (_BAD)"
        code, out, _ = _run(["claim", "--task-id", "tokenless", "--owner", "agent-fresh"])
        assert code == 0, "the task-id must be immediately claimable fresh, not wedged by the tokenless record"

        # Round-5 Bug B regression: a NUL-byte token IS a non-empty string, so the old "non-empty
        # string" check would have wrongly accepted it -- but no real CLI can ever supply a --token
        # argv value containing an embedded NUL byte, so a record carrying one is just as permanently
        # unwedgeable as a missing token. It must be rejected by the exact secrets.token_hex(16) shape
        # check, not just truthiness.
        bad_before = _BAD
        with LEDGER.open("a") as f:
            f.write(json.dumps({"ev": "claimed", "task_id": "nultoken", "owner": "agent-z",
                                 "token": "\u0000", "ts": time.strftime("%Y-%m-%dT%H:%M:%S")}) + "\n")
        assert "nultoken" not in open_claims(), "a NUL-byte-token claimed record must NOT fold into an open claim"
        code, out, _ = _run(["status"])
        assert code == 0 and "nultoken" not in out, "status must not show a NUL-byte-token record as open"
        _recs()  # refresh _BAD as a side effect
        assert _BAD > bad_before, "a NUL-byte-token claimed record must be counted as malformed (_BAD)"
        code, out, _ = _run(["claim", "--task-id", "nultoken", "--owner", "agent-fresh"])
        assert code == 0, "the task-id must be immediately claimable fresh, not wedged by the NUL-byte-token record"

        # real concurrency: N threads racing to claim the SAME task-id simultaneously must yield exactly
        # one winner, and the ledger must end up with exactly one 'claimed' record for it -- proves the
        # fcntl lock (and folding inside it) actually serializes the read-check-append, not just in theory.
        results = []
        barrier = threading.Barrier(8)

        def _attempt(i):
            barrier.wait()
            try:
                main(["claim", "--task-id", "conc", "--owner", f"agent-{i}"])
                results.append(True)
            except SystemExit:
                results.append(False)

        threads = [threading.Thread(target=_attempt, args=(i,)) for i in range(8)]
        with contextlib.redirect_stdout(io.StringIO()):
            for t in threads:
                t.start()
            for t in threads:
                t.join()
        assert results.count(True) == 1, "exactly one concurrent claim on the same task-id must win"
        claimed_for_conc = [r for r in _recs() if r["ev"] == "claimed" and r["task_id"] == "conc"]
        assert len(claimed_for_conc) == 1, "the lock must prevent more than one 'claimed' record for the same task-id"
    finally:
        LEDGER = orig_ledger
        shutil.rmtree(tmpdir, ignore_errors=True)


def _selfcheck_default_ledger_path():
    # Bug A regression test: with SM_CLAIM_LEDGER and SM_LOOP_STATE both unset, two claim-ledger.py
    # invocations from DIFFERENT CWDs inside the SAME git repo (the primary checkout + a linked
    # worktree) must resolve to the IDENTICAL default ledger file -- otherwise two sub-agent-supervisors,
    # each in their own worktree (the normal herdr setup), could each 'succeed' at claiming the same
    # task-id in blissful ignorance of each other. Only a real subprocess per CWD can test this
    # faithfully -- a frozen in-process global can't model 'a different process started elsewhere'.
    tmp = tempfile.mkdtemp(prefix="claim-ledger-pathcheck-")
    try:
        repo = os.path.join(tmp, "repo")
        subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
        subprocess.run(["git", "-C", repo, "config", "user.email", "a@a"], check=True)
        subprocess.run(["git", "-C", repo, "config", "user.name", "a"], check=True)
        with open(os.path.join(repo, "f"), "w") as f:
            f.write("x")
        subprocess.run(["git", "-C", repo, "add", "-A"], check=True)
        subprocess.run(["git", "-C", repo, "commit", "-q", "-m", "init"], check=True)
        wt = os.path.join(tmp, "wt")
        subprocess.run(["git", "-C", repo, "worktree", "add", "-q", "-b", "feat", wt, "main"], check=True)

        env = {k: v for k, v in os.environ.items() if k not in ("SM_CLAIM_LEDGER", "SM_LOOP_STATE")}

        def _cli(cwd, argv):
            return subprocess.run([sys.executable, _SCRIPT_PATH] + argv, cwd=cwd, env=env,
                                   capture_output=True, text=True)

        p1 = _cli(repo, ["claim", "--task-id", "shared-task", "--owner", "supervisor-a"])
        assert p1.returncode == 0, f"claim from the primary checkout should succeed: {p1.stderr}"
        p2 = _cli(wt, ["claim", "--task-id", "shared-task", "--owner", "supervisor-b"])
        assert p2.returncode != 0, (
            "claim from a DIFFERENT worktree of the SAME repo, same task-id, must be rejected -- if it "
            "succeeds, the two CWDs resolved to two different (unshared) default ledger files")

        common_dir = subprocess.run(["git", "-C", repo, "rev-parse", "--git-common-dir"],
                                     capture_output=True, text=True, check=True).stdout.strip()
        common_dir_path = pathlib.Path(common_dir)
        if not common_dir_path.is_absolute():
            common_dir_path = pathlib.Path(repo) / common_dir_path
        expected = common_dir_path.resolve().parent / ".secondmate" / "claims.jsonl"
        assert expected.exists(), f"expected the shared default ledger to land at {expected}"
        recs = [json.loads(line) for line in expected.read_text().splitlines() if line.strip()]
        assert any(r.get("task_id") == "shared-task" and r.get("owner") == "supervisor-a" for r in recs), (
            "the shared default ledger did not record the expected claim")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _selfcheck_no_git_fallback_warns():
    # Outside any git repo (SM_CLAIM_LEDGER/SM_LOOP_STATE both unset), the CWD-relative fallback must
    # still work, but must warn loudly on stderr -- never silently succeed with an unshared ledger.
    tmp = tempfile.mkdtemp(prefix="claim-ledger-nogit-")
    try:
        env = {k: v for k, v in os.environ.items() if k not in ("SM_CLAIM_LEDGER", "SM_LOOP_STATE")}
        p = subprocess.run([sys.executable, _SCRIPT_PATH, "claim", "--task-id", "t", "--owner", "a"],
                            cwd=tmp, env=env, capture_output=True, text=True)
        assert p.returncode == 0, f"claim outside a git repo should still work via the fallback: {p.stderr}"
        assert "WARNING" in p.stderr and "git" in p.stderr.lower(), (
            "the no-git fallback must warn loudly on stderr, not silently succeed")
        assert (pathlib.Path(tmp) / ".secondmate" / "claims.jsonl").exists(), (
            "fallback ledger should land at ./.secondmate/claims.jsonl relative to the CWD")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _selfcheck_bare_repos_dont_collide():
    # Bug A regression: for a BARE repo, `git rev-parse --git-common-dir` returns '.' (the bare repo IS
    # its own common-dir) -- taking its PARENT (as the non-bare case correctly does) lands OUTSIDE the
    # bare repo entirely, in whatever directory happens to contain it, colliding with any unrelated
    # sibling bare repo placed nearby (same collision class as a submodule's git-dir under a
    # superproject's .git/modules/). Two independent bare repos under the same parent directory must
    # resolve to two DIFFERENT default ledgers.
    tmp = tempfile.mkdtemp(prefix="claim-ledger-barecheck-")
    try:
        bare1 = os.path.join(tmp, "repo1.git")
        bare2 = os.path.join(tmp, "repo2.git")
        subprocess.run(["git", "init", "-q", "--bare", bare1], check=True)
        subprocess.run(["git", "init", "-q", "--bare", bare2], check=True)

        env = {k: v for k, v in os.environ.items() if k not in ("SM_CLAIM_LEDGER", "SM_LOOP_STATE")}

        def _cli(cwd, argv):
            return subprocess.run([sys.executable, _SCRIPT_PATH] + argv, cwd=cwd, env=env,
                                   capture_output=True, text=True)

        p1 = _cli(bare1, ["claim", "--task-id", "bare-task", "--owner", "supervisor-a"])
        assert p1.returncode == 0, f"claim inside bare repo 1 should succeed: {p1.stderr}"
        p2 = _cli(bare2, ["claim", "--task-id", "bare-task", "--owner", "supervisor-b"])
        assert p2.returncode == 0, (
            "claim inside an UNRELATED bare repo, same task-id, must succeed independently -- if it's "
            f"rejected, the two bare repos collided on the same default ledger: {p2.stderr}")

        ledger1 = pathlib.Path(bare1) / ".secondmate" / "claims.jsonl"
        ledger2 = pathlib.Path(bare2) / ".secondmate" / "claims.jsonl"
        assert ledger1.exists(), f"expected bare repo 1's default ledger at {ledger1}"
        assert ledger2.exists(), f"expected bare repo 2's default ledger at {ledger2}"
        assert ledger1.resolve() != ledger2.resolve(), "the two bare repos must NOT share a default ledger"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _selfcheck_submodules_dont_collide():
    # Round-5 Bug A regression: for a SUBMODULE, `git rev-parse --git-common-dir` resolves to something
    # like '.git/modules/<name>' -- basename is the submodule's own name, NOT '.git'. The bare-repo-only
    # special case from round 4 did not cover this: it fell through to the normal 'anchor at parent'
    # branch, and TWO DIFFERENT submodules of the same superproject ('.git/modules/one',
    # '.git/modules/two') both resolve to the SAME parent ('.git/modules/'), colliding. Two independent
    # submodules under one superproject must resolve to two DIFFERENT default ledgers.
    tmp = tempfile.mkdtemp(prefix="claim-ledger-submodulecheck-")
    try:
        lib = os.path.join(tmp, "lib")
        subprocess.run(["git", "init", "-q", "-b", "main", lib], check=True)
        subprocess.run(["git", "-C", lib, "config", "user.email", "a@a"], check=True)
        subprocess.run(["git", "-C", lib, "config", "user.name", "a"], check=True)
        with open(os.path.join(lib, "f"), "w") as f:
            f.write("x")
        subprocess.run(["git", "-C", lib, "add", "-A"], check=True)
        subprocess.run(["git", "-C", lib, "commit", "-q", "-m", "init"], check=True)

        super_repo = os.path.join(tmp, "super")
        subprocess.run(["git", "init", "-q", "-b", "main", super_repo], check=True)
        subprocess.run(["git", "-C", super_repo, "config", "user.email", "a@a"], check=True)
        subprocess.run(["git", "-C", super_repo, "config", "user.name", "a"], check=True)
        with open(os.path.join(super_repo, "g"), "w") as f:
            f.write("y")
        subprocess.run(["git", "-C", super_repo, "add", "-A"], check=True)
        subprocess.run(["git", "-C", super_repo, "commit", "-q", "-m", "init"], check=True)
        # local-path submodules need file protocol explicitly allowed (git disables it by default).
        subprocess.run(["git", "-C", super_repo, "-c", "protocol.file.allow=always",
                         "submodule", "add", "-q", lib, "sub1"], check=True)
        subprocess.run(["git", "-C", super_repo, "-c", "protocol.file.allow=always",
                         "submodule", "add", "-q", lib, "sub2"], check=True)
        subprocess.run(["git", "-C", super_repo, "commit", "-q", "-m", "add submodules"], check=True)

        sub1 = os.path.join(super_repo, "sub1")
        sub2 = os.path.join(super_repo, "sub2")
        env = {k: v for k, v in os.environ.items() if k not in ("SM_CLAIM_LEDGER", "SM_LOOP_STATE")}

        def _cli(cwd, argv):
            return subprocess.run([sys.executable, _SCRIPT_PATH] + argv, cwd=cwd, env=env,
                                   capture_output=True, text=True)

        p1 = _cli(sub1, ["claim", "--task-id", "sub-task", "--owner", "supervisor-a"])
        assert p1.returncode == 0, f"claim inside submodule 1 should succeed: {p1.stderr}"
        p2 = _cli(sub2, ["claim", "--task-id", "sub-task", "--owner", "supervisor-b"])
        assert p2.returncode == 0, (
            "claim inside an UNRELATED submodule of the same superproject, same task-id, must succeed "
            f"independently -- if it's rejected, the two submodules collided on the same default "
            f"ledger: {p2.stderr}")

        common1 = subprocess.run(["git", "-C", sub1, "rev-parse", "--git-common-dir"],
                                  capture_output=True, text=True, check=True).stdout.strip()
        common2 = subprocess.run(["git", "-C", sub2, "rev-parse", "--git-common-dir"],
                                  capture_output=True, text=True, check=True).stdout.strip()
        ledger1 = (pathlib.Path(sub1) / common1).resolve() / ".secondmate" / "claims.jsonl"
        ledger2 = (pathlib.Path(sub2) / common2).resolve() / ".secondmate" / "claims.jsonl"
        assert ledger1.exists(), f"expected submodule 1's default ledger at {ledger1}"
        assert ledger2.exists(), f"expected submodule 2's default ledger at {ledger2}"
        assert ledger1 != ledger2, "the two submodules must NOT share a default ledger"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    p = argparse.ArgumentParser(description="atomic task-id claims for concurrent sub-agent-supervisors")
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("claim")
    c.add_argument("--task-id", required=True)
    c.add_argument("--owner", required=True)

    r = sub.add_parser("release")
    r.add_argument("--task-id", required=True)
    r.add_argument("--owner", required=True)
    r.add_argument("--token", required=True)

    s = sub.add_parser("steal")
    s.add_argument("--task-id", required=True)
    s.add_argument("--owner", required=True)
    s.add_argument("--reason", required=True)

    sub.add_parser("status")
    sub.add_parser("list")
    sub.add_parser("selfcheck")
    args = p.parse_args(argv)

    if args.cmd in ("claim", "release", "steal"):
        if not _valid_task_id(args.task_id):
            sys.exit(f"invalid --task-id {args.task_id!r}: must match [A-Za-z0-9_-] and be 1-128 chars "
                      f"(no path separators, no null bytes, no empty string)")
        if not args.owner:
            sys.exit("--owner must be non-empty")

    if args.cmd == "claim":
        with _ledger_lock():   # read-check-append is atomic vs a concurrent claim/steal on the same task-id
            opened = open_claims()
            existing = opened.get(args.task_id)
            if existing is not None:
                sys.exit(f"task-id {args.task_id} is already claimed by {existing['owner']} "
                         f"(since {existing.get('ts', '?')}) -- release it first, or --steal with a reason")
            ts = time.strftime("%Y-%m-%dT%H:%M:%S")
            # a real, unguessable secret -- --owner alone is just a human-readable label a bug or a
            # mislabeled caller could trivially repeat; this token is the actual release-time proof.
            token = secrets.token_hex(16)
            _append({"ev": "claimed", "task_id": args.task_id, "owner": args.owner, "token": token, "ts": ts})
        print(f"claimed {args.task_id} for {args.owner} token={token}")

    elif args.cmd == "release":
        with _ledger_lock():
            opened = open_claims()
            existing = opened.get(args.task_id)
            if existing is None:
                sys.exit(f"no open claim for task-id {args.task_id} -- nothing to release")
            if existing["owner"] != args.owner:
                sys.exit(f"task-id {args.task_id} is claimed by {existing['owner']}, not {args.owner} "
                         f"-- refusing release (use --steal with a reason if this is a deliberate override)")
            if existing.get("token") != args.token:
                sys.exit(f"task-id {args.task_id}'s claim token does not match the supplied --token -- "
                         f"refusing release (wrong or missing token; use --steal with a reason if this is a "
                         f"deliberate override)")
            ts = time.strftime("%Y-%m-%dT%H:%M:%S")
            _append({"ev": "released", "task_id": args.task_id, "owner": args.owner, "ts": ts})
        print(f"released {args.task_id}")

    elif args.cmd == "steal":
        if not args.reason.strip():
            sys.exit("--reason must be non-empty -- steal is a human-supervised override and the ledger "
                      "must record why the claim was reclaimed")
        with _ledger_lock():
            # Fold FRESH, inside the lock, right before deciding -- never trust an earlier snapshot.
            opened = open_claims()
            prev = opened.get(args.task_id)
            ts = time.strftime("%Y-%m-%dT%H:%M:%S")
            # steal itself needs no --token (it's the no-proof-required human-override escape hatch),
            # but the claim it OPENS is a normal new claim and needs its own fresh token too, or its new
            # owner could never `release` it through the ownership-checked path afterward.
            token = secrets.token_hex(16)
            rec = {"ev": "stolen", "task_id": args.task_id, "owner": args.owner, "token": token, "ts": ts,
                   "reason": args.reason}
            if prev is not None:
                rec["previous_owner"] = prev["owner"]
            _append(rec)
        if prev is not None:
            print(f"stole {args.task_id} from {prev['owner']} for {args.owner} token={token}: {args.reason}")
        else:
            print(f"claimed (via steal, no prior open claim) {args.task_id} for {args.owner} token={token}: {args.reason}")

    elif args.cmd in ("status", "list"):
        opened = open_claims()
        if not opened and _BAD == 0:
            print("(no open claims)", file=sys.stderr)  # stderr keeps stdout clean when empty
        for task_id, r in sorted(opened.items()):
            print(f"[{task_id}] owner={r['owner']} claimed_at={r.get('ts', '?')}")
        if _BAD:  # surface corruption on stdout -- never fail open
            print(f"WARNING: {_BAD} malformed line(s) in {LEDGER} -- ledger may be corrupt; reconcile manually.")

    elif args.cmd == "selfcheck":
        recs = [{"ev": "claimed", "task_id": "t", "owner": "a", "ts": "1"},
                 {"ev": "claimed", "task_id": "u", "owner": "b", "ts": "2"},
                 {"ev": "released", "task_id": "t", "owner": "a", "ts": "3"}]
        assert set(open_claims(recs).keys()) == {"u"}, "open-fold broken"
        recs2 = recs + [{"ev": "stolen", "task_id": "u", "owner": "c", "ts": "4", "reason": "x"}]
        assert open_claims(recs2)["u"]["owner"] == "c", "stolen event must reopen the claim under the new owner"
        assert open_claims([]) == {}, "empty ledger must fold to no open claims"
        assert _valid_task_id("sm-abc_123") and not _valid_task_id("../x") and not _valid_task_id("") \
            and not _valid_task_id("a/b") and not _valid_task_id("a" * 129), "task-id validation broken"
        _selfcheck_live()
        _selfcheck_default_ledger_path()
        _selfcheck_no_git_fallback_warns()
        _selfcheck_bare_repos_dont_collide()
        _selfcheck_submodules_dont_collide()
        print("ok")


if __name__ == "__main__":
    main(sys.argv[1:])
