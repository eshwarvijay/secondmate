#!/usr/bin/env python3
# ponytail: append-only JSONL ledger, fcntl-locked -- same idiom as claim-ledger.py/progress-ledger.py.
# No daemon, no heartbeat thread: each invocation is a single poll, scheduled externally (e.g. a
# ScheduleWakeup-driven interval), never continuous.
"""pane-reaper.py -- detects (never acts on) herdr panes/agents that have gone quiet.

VERIFIED LIVE FACT (herdr's own `herdr pane list` / `herdr agent list`, HERDR_ENV=1): neither call
exposes an activity timestamp anywhere. The only state that changes as a pane does work is a handful of
monotonic counters -- `revision` (pane list AND agent list), `state_change_seq` (agent list only),
`agent_status` (working/idle/blocked/done/unknown) -- plus `focused`. "Quiet past a threshold" can
therefore only be derived from THIS SCRIPT's own observation history (comparing that counter/status tuple
across its own successive polls), never from a herdr-reported "last active" field, because no such field
exists.

  pane-reaper.py observe                                     -> queries `herdr pane list` + `herdr agent
                                                                   list` (JSON), appends ONE observation row
                                                                   per pane to this script's OWN ledger (a
                                                                   separate file from progress.jsonl/
                                                                   claims.jsonl -- a separate concern).
                                                                   Exits 0 on success, ERR_HERDR (2) if
                                                                   herdr itself is unreachable or its output
                                                                   is unparseable -- NEVER folded silently
                                                                   into "observed nothing", so a tooling
                                                                   outage is never mistaken for "all quiet".
  pane-reaper.py quiet --threshold-seconds N                  -> N must be a WHOLE number of seconds > 0
                                                                   (argparse `type=int`, same int-only
                                                                   posture as progress-ledger.py's own
                                                                   `stale --threshold-seconds`; a
                                                                   fractional value like "1.5" is
                                                                   rejected at the argparse layer itself,
                                                                   before this script's own validation
                                                                   ever runs) -- rejected otherwise,
                                                                   nonzero exit; read-only, mirrors
                                                                   progress-ledger.py's own `stale`
                                                                   contract exactly: one JSON
                                                                   line per quiet pane, exit 1 if any hit,
                                                                   exit 0 if clean. Never appends, never
                                                                   calls herdr. A pane is reported only once
                                                                   its (revision, agent_status,
                                                                   state_change_seq) signature has stayed
                                                                   IDENTICAL across a contiguous run of at
                                                                   least two of this script's own
                                                                   observations, with the EARLIEST
                                                                   observation in that unchanged run at
                                                                   least N seconds old. A pane with only ONE
                                                                   observation ever is NEVER reported --
                                                                   there is no second data point to prove
                                                                   staleness against, so (like progress-
                                                                   ledger.py's own "no_progress_recorded" vs
                                                                   "stale" split) insufficient history is
                                                                   kept honestly distinct from quiet, never
                                                                   conflated with it. Conservative by
                                                                   design: this can under-report (miss a
                                                                   quiet pane it hasn't polled twice yet)
                                                                   but can never false-positive a brand-new
                                                                   pane.
  pane-reaper.py selfcheck                                    -> asserts the fold + drives the real CLI
                                                                   paths against a scratch ledger, with
                                                                   `herdr` itself faked via a PATH shim
                                                                   (same technique bin/teardown-check.sh's
                                                                   own selfcheck already uses to fake an
                                                                   external CLI) -- never requires a live
                                                                   herdr session or HERDR_ENV=1.

DETECTION ONLY, matching progress-ledger.py's own documented stance verbatim: "No auto-restart, ... no
attempt at real-time detection". This script NEVER kills, restarts, signals (SIGSTOP or otherwise), or
mutates any pane, agent, or process in any way -- it only reads herdr's own read-only list output and
appends to its own ledger. `quiet` only ever reports; whoever calls it decides what to do, and per the
same precedent, that action is always "surface to a human", never automatic.

Ledger path resolution is IDENTICAL in shape to claim-ledger.py's/progress-ledger.py's own (first match
wins), for the same shared-worktree reason:
  1. $SM_PANE_LEDGER, if set -- used exactly as given.
  2. $SM_LOOP_STATE/panes.jsonl, if $SM_LOOP_STATE is set.
  3. Otherwise, anchored to `git rev-parse --git-common-dir`'s parent (or the common-dir itself for a bare
     repo or a submodule -- see claim-ledger.py's own docstring for the full rationale). Falls back to a
     CWD-relative `.secondmate/panes.jsonl` (with a loud stderr warning) only if not inside a git repo.

This script never touches claim-ledger.py's or progress-ledger.py's own ledgers, schemas, or event types --
a separate file, a separate ledger, a separate concern (pane activity, not claim ownership or checkpoints).
"""
import json, sys, os, time, math, subprocess, argparse, pathlib, contextlib, io, tempfile, shutil
try:
    import fcntl
except ImportError:  # non-Unix (e.g. Windows) -> best-effort, no locking
    fcntl = None

_SCRIPT_PATH = os.path.abspath(__file__)

ERR_HERDR = 2  # distinct from quiet's 0 (clean) / 1 (hits) -- a tooling outage must never look like "clean"


def _default_ledger_path():
    """Identical resolution to claim-ledger.py's/progress-ledger.py's own _default_ledger_path -- see
    claim-ledger.py's docstring for the full bare-repo/submodule rationale. Copied rather than imported:
    every bin/ script here is a standalone single-file CLI by this repo's own convention (no shared
    internal module)."""
    if os.environ.get("SM_PANE_LEDGER"):
        return pathlib.Path(os.environ["SM_PANE_LEDGER"])
    if os.environ.get("SM_LOOP_STATE"):
        return pathlib.Path(os.environ["SM_LOOP_STATE"]) / "panes.jsonl"
    try:
        out = subprocess.run(["git", "rev-parse", "--git-common-dir"], capture_output=True, text=True)
        if out.returncode == 0 and out.stdout.strip():
            common_dir = pathlib.Path(out.stdout.strip())
            if not common_dir.is_absolute():
                common_dir = pathlib.Path.cwd() / common_dir
            common_dir = common_dir.resolve()
            anchor = common_dir if common_dir.name != ".git" else common_dir.parent
            return anchor / ".secondmate" / "panes.jsonl"
    except OSError:
        pass
    sys.stderr.write(
        "WARNING: pane-reaper.py could not resolve a git-common-dir (not inside a git repo, or git not "
        "found) -- falling back to a CWD-relative ./.secondmate/panes.jsonl, which will NOT be shared "
        "across other worktrees/CWDs. Set SM_PANE_LEDGER to a shared path.\n")
    return pathlib.Path(".secondmate") / "panes.jsonl"


LEDGER = _default_ledger_path()
_BAD = 0  # count of malformed/incomplete ledger lines seen by the last _recs()


def _valid_positive_number(x):
    # same finite-number idiom as progress-ledger.py's own budget-field validator, but requiring
    # STRICTLY positive: a "quiet for N seconds" threshold of zero or less describes no real duration.
    # CONFIRMED BUG (checker, round 1): a negative --threshold-seconds was previously accepted with no
    # validation at all, making `age >= threshold_seconds` trivially true for any observed age (age is
    # never negative), so every multi-observation pane was reported quiet instantly regardless of actual
    # elapsed time.
    if isinstance(x, bool):
        return False
    if isinstance(x, int):
        # CONFIRMED BUG (checker round 2 -> round 3, independently reconfirmed by the supervisor):
        # calling math.isfinite(x) on a native Python int implicitly converts it to a float first --
        # for an arbitrarily large int (argparse's own type=int on --threshold-seconds imposes no upper
        # bound), that conversion itself raises OverflowError ("int too large to convert to float"), an
        # UNCAUGHT exception/stack trace instead of a clean accept or reject. A native int has no
        # "infinite" representation at all (arbitrary precision, never nan/inf -- those strings already
        # fail earlier at argparse's own int() parsing), so math.isfinite is unnecessary and actively
        # harmful here: just compare directly.
        return x > 0
    if isinstance(x, float):
        return math.isfinite(x) and x > 0
    return False


def _valid_ts(ts):
    # a "ts" that isn't a string in this script's own written shape can never be folded into an epoch --
    # same posture as claim-ledger.py/progress-ledger.py treating a malformed field as corruption, not a
    # valid observation.
    if not isinstance(ts, str):
        return False
    try:
        time.strptime(ts, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return False
    return True


def _recs():
    # tolerant parse: skip malformed/incomplete lines but COUNT them -- same discipline as
    # claim-ledger.py/progress-ledger.py, so `quiet` warns instead of a partial write silently hiding an
    # observation.
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
        except (ValueError, RecursionError):
            # CONFIRMED BUG (checker): a deeply-nested but syntactically valid JSON line (e.g. ~1100
            # levels of nested arrays) raises RecursionError, not ValueError -- the same class already
            # fixed in this script's own _herdr_json. Must be treated as any other malformed/unparseable
            # line: counted in _BAD, skipped, never crash the whole read.
            _BAD += 1; continue
        valid = (isinstance(o, dict) and o.get("ev") == "pane_observed"
                 and isinstance(o.get("pane_id"), str) and _valid_ts(o.get("ts")))
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
    # Same fcntl idiom as claim-ledger.py/progress-ledger.py's own _ledger_lock(): serialize concurrent
    # appends with an exclusive OS lock on a sibling .lock file, so ledger append order under the lock IS
    # the true chronological order (what the quiet-fold's "earliest observation in the unchanged run"
    # logic relies on).
    if fcntl is None:
        yield; return
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    with open(str(LEDGER) + ".lock", "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


class _HerdrError(Exception):
    """herdr itself is unreachable, exited nonzero, or produced unparseable JSON -- distinct from 'herdr
    ran fine and reported zero panes', so a tooling outage is never silently folded into 'nothing
    quiet'."""


def _herdr_json(argv):
    # CONFIRMED BUG (checker, round 9): text=True makes subprocess.run decode stdout/stderr as UTF-8
    # itself -- if herdr exits 0 but emits an invalid UTF-8 byte (e.g. a stray 0xff) in its stdout, that
    # decode raises an uncaught UnicodeDecodeError, crashing `observe` with exit 1 instead of the designed
    # ERR_HERDR path. Capture raw bytes instead and decode tolerantly (errors="replace") ourselves, so an
    # invalid-byte response degrades to a parseable-but-wrong string -- which then correctly fails
    # json.loads below and raises _HerdrError -- rather than crashing at the decode step itself.
    try:
        out = subprocess.run(["herdr"] + argv, capture_output=True, text=False, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise _HerdrError(f"could not run `herdr {' '.join(argv)}`: {e}")
    stdout = out.stdout.decode("utf-8", errors="replace")
    stderr = out.stderr.decode("utf-8", errors="replace")
    if out.returncode != 0:
        raise _HerdrError(f"`herdr {' '.join(argv)}` exited {out.returncode}: {stderr.strip()}")
    try:
        return json.loads(stdout)
    except ValueError as e:
        raise _HerdrError(f"`herdr {' '.join(argv)}` produced unparseable JSON: {e}")
    except RecursionError as e:
        # CONFIRMED BUG (checker round 4): a deeply-nested but otherwise syntactically valid JSON response
        # overflows the recursive JSON decoder's call stack -- an uncaught RecursionError instead of the
        # designed ERR_HERDR path. Fold it into the same _HerdrError handling as any other malformed herdr
        # response rather than letting it crash `observe` with exit 1.
        raise _HerdrError(f"`herdr {' '.join(argv)}` produced too-deeply-nested JSON: {e}")


def _require_list(obj, path, context):
    """Walk `obj` via a dotted `path` of nested dict keys (e.g. "result.panes") and return the list at
    that path -- raises _HerdrError if ANY key along the way is missing, or if the final value isn't a
    list. This is the TOP-LEVEL shape check: CONFIRMED BUG (checker, round 1) -- a syntactically valid
    but structurally wrong response (e.g. a bare `{}`, or a future herdr API shape change dropping
    `result.panes`/`result.agents` entirely) previously fell through to an empty list silently, so
    `observe` reported "observed 0 pane(s)" with exit 0 -- a false-clean result that hides a genuine
    herdr-output problem behind the exact "nothing to see" signal this watchdog exists to never give.
    This is DELIBERATELY distinct from an individual malformed ENTRY inside an otherwise well-shaped
    list (e.g. one pane dict missing its own `pane_id`) -- that case is still tolerated and the single
    bad entry is just skipped, by the per-entry loops in `_snapshot_panes` below; only a broken TOP-LEVEL
    shape escalates to a loud, distinct herdr-output failure."""
    cur = obj
    keys = path.split(".")
    for k in keys:
        if not isinstance(cur, dict) or k not in cur:
            raise _HerdrError(f"expected `{path}` in herdr's {context} response, got {obj!r}")
        cur = cur[k]
    if not isinstance(cur, list):
        raise _HerdrError(f"expected `{path}` in herdr's {context} response to be a list, got {cur!r}")
    return cur


def _snapshot_panes():
    """Query herdr's own read-only pane/agent list (never anything mutating) and fold them into one
    {pane_id: {revision, agent_status, focused, state_change_seq}} snapshot -- state_change_seq is only
    present for panes `agent list` itself returns (a pane with no agent attached has none). The TOP-LEVEL
    `result.panes`/`result.agents` shape must actually be present (see _require_list) -- that failure
    mode propagates to the caller as _HerdrError, never silently yielding an empty snapshot. Tolerant
    only of a malformed or missing field on an individual ENTRY within an otherwise well-shaped list -- a
    single bad entry is skipped, not a crash."""
    pane_list = _herdr_json(["pane", "list"])
    agent_list = _herdr_json(["agent", "list"])

    panes_raw = _require_list(pane_list, "result.panes", "`herdr pane list`")
    agents_raw = _require_list(agent_list, "result.agents", "`herdr agent list`")

    state_change_seq_by_pane = {}
    for a in agents_raw:
        if isinstance(a, dict) and isinstance(a.get("pane_id"), str) and "state_change_seq" in a:
            state_change_seq_by_pane[a["pane_id"]] = a.get("state_change_seq")

    snapshot = {}
    for p in panes_raw:
        if not (isinstance(p, dict) and isinstance(p.get("pane_id"), str)):
            continue  # malformed entry (e.g. no pane_id) -- skip, don't crash the whole poll
        pane_id = p["pane_id"]
        snapshot[pane_id] = {
            "revision": p.get("revision"),
            "agent_status": p.get("agent_status"),
            "focused": p.get("focused"),
            "state_change_seq": state_change_seq_by_pane.get(pane_id),
        }
    return snapshot


def _signature(obs):
    return (obs.get("revision"), obs.get("agent_status"), obs.get("state_change_seq"))


def _observations_by_pane(recs=None):
    """Fold the ledger to {pane_id: [observation rows in ledger append order]}. Append order under this
    script's own fcntl lock IS true chronological order -- same precedent progress-ledger.py's own
    latest_by_task fold relies on."""
    recs = _recs() if recs is None else recs
    by_pane = {}
    for r in recs:
        by_pane.setdefault(r["pane_id"], []).append(r)
    return by_pane


def _ts_to_epoch(ts):
    # a ts that passed _valid_ts's own format check (so it parses fine as a *syntactically* valid
    # timestamp via strptime) can still be numerically out of time.mktime's representable range -- e.g.
    # an extreme/corrupted year like "0001". CONFIRMED BUG (checker): this previously crashed `quiet`
    # with an uncaught OverflowError instead of being treated as unusable/corrupt data, the same
    # tolerant-parse-but-don't-crash discipline progress-ledger.py's own _recs() already applies
    # elsewhere. Returns None on failure so the caller can skip the observation conservatively -- same
    # never-false-positive posture already used for insufficient history.
    try:
        return time.mktime(time.strptime(ts, "%Y-%m-%dT%H:%M:%S"))
    except (OverflowError, OSError, ValueError):
        return None


def find_quiet(by_pane, threshold_seconds, now=None):
    """A pane qualifies only once its signature has stayed identical across a contiguous run of AT LEAST
    TWO observations ending at the latest one, with the EARLIEST observation in that run at least
    threshold_seconds old. A pane with a single observation (len < 2), or whose latest signature differs
    from the one recorded right before it (a contiguous run of length 1), is never reported --
    conservative by design: insufficient history is never treated as proof of staleness."""
    now = time.time() if now is None else now
    hits = []
    for pane_id, obs in sorted(by_pane.items()):
        if len(obs) < 2:
            continue
        latest = obs[-1]
        sig = _signature(latest)
        since_idx = len(obs) - 1
        for i in range(len(obs) - 2, -1, -1):
            if _signature(obs[i]) == sig:
                since_idx = i
            else:
                break
        if since_idx == len(obs) - 1:
            continue  # the signature changed since the observation right before latest -- not quiet
        since = obs[since_idx]
        # CONFIRMED BUG (checker, post-round-5): checking only `since` (the earliest observation in the
        # run) let a LATER observation in the same contiguous run with an unconvertible ts (e.g. an
        # out-of-range year) slip through unnoticed, since only `since_epoch` feeds the age math below --
        # the pane would be wrongly reported quiet using the earlier, convertible timestamp. Must check
        # EVERY observation in the run [since_idx:latest]; if any is unconvertible, exclude the pane
        # entirely -- same never-false-positive posture as the single-observation case.
        if any(_ts_to_epoch(o["ts"]) is None for o in obs[since_idx:]):
            continue
        since_epoch = _ts_to_epoch(since["ts"])
        age = now - since_epoch
        if age >= threshold_seconds:
            hits.append({"pane_id": pane_id, "status": "quiet", "revision": sig[0], "agent_status": sig[1],
                         "state_change_seq": sig[2], "since_ts": since["ts"], "age_seconds": int(age)})
    return hits


def _run(argv):
    # selfcheck helper: invoke the REAL main() and capture the result -- same precedent
    # claim-ledger.py/progress-ledger.py's own _run helper establishes, never reimplement main()'s logic.
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


def _write_fake_herdr(bindir, pane_list_obj=None, agent_list_obj=None, fail=False,
                       raw_pane_list=None, raw_agent_list=None):
    """Writes a fake `herdr` executable into bindir (meant to be PATH-shimmed ahead of the real one) --
    same technique bin/teardown-check.sh's own selfcheck already uses to fake an external CLI without a
    live session."""
    script = bindir / "herdr"
    if fail:
        content = "#!/usr/bin/env bash\necho '{\"error\":\"boom\"}' >&2\nexit 1\n"
    else:
        pane_json = raw_pane_list if raw_pane_list is not None else json.dumps(pane_list_obj)
        agent_json = raw_agent_list if raw_agent_list is not None else json.dumps(agent_list_obj)
        content = f"""#!/usr/bin/env bash
if [ "$1" = "pane" ] && [ "$2" = "list" ]; then
cat <<'PANE_EOF'
{pane_json}
PANE_EOF
exit 0
fi
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
cat <<'AGENT_EOF'
{agent_json}
AGENT_EOF
exit 0
fi
echo "unexpected herdr args: $@" >&2
exit 1
"""
    script.write_text(content)
    script.chmod(0o755)


def _pane_list_json(entries):
    return {"id": "cli:pane:list", "result": {"panes": entries, "type": "pane_list"}}


def _agent_list_json(entries):
    return {"id": "cli:agent:list", "result": {"agents": entries, "type": "agent_list"}}


def _selfcheck_live():
    global LEDGER
    orig_ledger = LEDGER
    orig_path = os.environ.get("PATH", "")
    tmpdir = tempfile.mkdtemp(prefix="pane-reaper-selfcheck-")
    LEDGER = pathlib.Path(tmpdir) / "panes.jsonl"
    bindir = pathlib.Path(tmpdir) / "fakebin"
    bindir.mkdir()
    os.environ["PATH"] = f"{bindir}{os.pathsep}{orig_path}"
    try:
        # Poll 1: two panes, both freshly observed for the first time.
        _write_fake_herdr(bindir,
            _pane_list_json([
                {"pane_id": "p1", "revision": 1, "agent_status": "working", "focused": True},
                {"pane_id": "p2", "revision": 5, "agent_status": "idle", "focused": False},
            ]),
            _agent_list_json([
                {"pane_id": "p1", "revision": 1, "agent_status": "working", "state_change_seq": 10},
                {"pane_id": "p2", "revision": 5, "agent_status": "idle", "state_change_seq": 2},
            ]))
        code, out, exc = _run(["observe"])
        assert code == 0 and exc is None, f"a valid observe call must succeed: {out}"
        assert len(_recs()) == 2, "observe must append exactly one row per pane"

        # a brand-new pane with only ONE observation ever must NEVER be reported, no matter the
        # threshold -- there is no second data point to prove staleness against yet. "1" is the
        # smallest valid --threshold-seconds (0 and negative values are rejected -- see below).
        code, out, exc = _run(["quiet", "--threshold-seconds", "1"])
        assert exc == 0 and out == "", (
            "a pane with only one observation ever must never be reported, even at the smallest valid threshold")

        # Poll 2: p1's signature is IDENTICAL to poll 1 (unchanging over this window); p2's signature
        # CHANGED (its revision/state_change_seq advanced -- genuinely busy).
        time.sleep(1.2)
        _write_fake_herdr(bindir,
            _pane_list_json([
                {"pane_id": "p1", "revision": 1, "agent_status": "working", "focused": True},
                {"pane_id": "p2", "revision": 9, "agent_status": "working", "focused": False},
            ]),
            _agent_list_json([
                {"pane_id": "p1", "revision": 1, "agent_status": "working", "state_change_seq": 10},
                {"pane_id": "p2", "revision": 9, "agent_status": "working", "state_change_seq": 7},
            ]))
        code, out, exc = _run(["observe"])
        assert code == 0 and exc is None
        assert len(_recs()) == 4, "the second observe must append two more rows, not overwrite the first"

        code, out, exc = _run(["quiet", "--threshold-seconds", "1"])
        assert exc == 1, "p1's unchanged signature spanning > 1s must be reported quiet"
        assert '"pane_id": "p1"' in out, f"expected p1 reported quiet: {out}"
        assert '"pane_id": "p2"' not in out, (
            f"p2's signature changed between polls -- it must never be reported quiet: {out}")

        # isolate the "signature changed -> never reported" guard from real-time timing entirely: append
        # (bypassing observe) two DISAGREEING, hours-old observations for a synthetic pane "p4". If the
        # guard that excludes a changed-signature pane were ever missing, a naive fallback to "the
        # latest observation's own age" would trivially exceed almost any threshold here (p4's latest
        # observation is itself 1 hour old) -- p4 must still never be reported, no matter how old its
        # observations are, because its last two disagree.
        hour_ago = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - 7200))
        half_hour_ago = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - 3600))
        _append({"ev": "pane_observed", "pane_id": "p4", "revision": 1, "agent_status": "idle", "ts": hour_ago})
        _append({"ev": "pane_observed", "pane_id": "p4", "revision": 2, "agent_status": "idle", "ts": half_hour_ago})
        code, out, exc = _run(["quiet", "--threshold-seconds", "1800"])
        assert '"pane_id": "p4"' not in out, (
            f"p4's last two observations disagree -- it must never be reported quiet no matter how old "
            f"its latest observation is: {out}")

        # the same ledger against a huge threshold must report nothing -- p1 hasn't been unchanged THAT
        # long yet.
        code, out, exc = _run(["quiet", "--threshold-seconds", "36000"])
        assert exc == 0 and out == "", "p1 must not be reported quiet against a threshold it hasn't met"

        # `quiet` never appends -- read-only, like progress-ledger.py's own `stale`.
        pre_len = len(_recs())
        _run(["quiet", "--threshold-seconds", "1"])
        assert len(_recs()) == pre_len, "quiet must never append to the ledger"

        # --threshold-seconds must be a finite, strictly positive number -- CONFIRMED BUG (checker,
        # round 1): a negative value was previously accepted with no validation at all, making
        # `age >= threshold_seconds` trivially true for any observed age (age is never negative), so
        # every multi-observation pane was reported quiet instantly regardless of real elapsed time.
        # Zero is rejected too (no real "unchanged for zero seconds" duration), matching this script's
        # own strictly-positive posture, not merely >= 0.
        pre_len = len(_recs())
        for bad in ("-1", "0", "-100", "nan", "inf", "-inf", "abc", "1.5"):
            code, out, _ = _run(["quiet", "--threshold-seconds", bad])
            # a bare `code != 0` alone is NOT sufficient here: the exact bug being guarded against makes
            # a negative/zero threshold trivially report every multi-observation pane as a HIT, which
            # ALSO exits nonzero (1) -- that would make this assertion pass even with the validation
            # missing. Require that NO hit was reported either -- true rejection happens before any fold
            # is even attempted, so no "quiet" JSON can appear on either path.
            assert code != 0 and '"status": "quiet"' not in out, (
                f"--threshold-seconds {bad!r} must be REJECTED outright, not silently treated as "
                f"'everything is quiet' (which would also exit nonzero, masking a missing validation): {out!r}")
        assert len(_recs()) == pre_len, "a rejected --threshold-seconds must never append to the ledger"

        # CONFIRMED BUG (checker round 2 -> round 3, independently reconfirmed by the supervisor): a
        # very large positive integer --threshold-seconds (e.g. a 1000-digit number) previously crashed
        # with an uncaught `OverflowError: int too large to convert to float` inside
        # _valid_positive_number's own math.isfinite(x) call, instead of being accepted (it IS finite
        # and > 0 as a native Python int, which has no "infinite" representation at all). Must now be
        # ACCEPTED and produce a clean, ordinary result -- no crash, no stack trace, exit 0 on an empty
        # ledger.
        huge = 10 ** 1000
        code, out, exc = _run(["quiet", "--threshold-seconds", str(huge)])
        assert exc == 0 and out == "", (
            f"a very large (1000-digit) positive integer --threshold-seconds must be accepted cleanly, "
            f"never crash: code={code} exc={exc} out={out!r}")
        assert _valid_positive_number(huge), "a huge positive int must be a VALID threshold (finite, > 0)"

        # CONFIRMED BUG (checker, full-diff review): two format-valid observations with an extreme
        # timestamp (e.g. year 0001) pass _valid_ts's own strptime-based format check fine, but
        # time.mktime on that same parsed struct raises an uncaught OverflowError -- the exact same
        # class of bug as the --threshold-seconds OverflowError fixed above, on the ledger-READ side
        # instead of the CLI-argument side. `quiet` must never crash on this; the pane with the
        # unconvertible timestamp must simply never be reported (same conservative,
        # never-false-positive posture as insufficient history), everything else unaffected.
        _append({"ev": "pane_observed", "pane_id": "extreme-ts", "revision": 1, "agent_status": "idle",
                 "ts": "0001-01-01T00:00:00"})
        _append({"ev": "pane_observed", "pane_id": "extreme-ts", "revision": 1, "agent_status": "idle",
                 "ts": "0001-01-01T00:00:01"})
        code, out, exc = _run(["quiet", "--threshold-seconds", "1"])
        assert exc in (0, 1), f"quiet must never crash on an extreme-but-format-valid timestamp: {out!r}"
        assert '"pane_id": "extreme-ts"' not in out, (
            f"a pane whose timestamp can't be converted to an epoch must never be reported quiet: {out!r}")

        # CONFIRMED BUG (checker, post-round-5): the round-5 fix above only checked the EARLIEST
        # ('since') observation's timestamp for convertibility, not every observation in the contiguous
        # same-signature run [since_idx:latest]. Two observations, same signature, where the EARLIER ts
        # is convertible but the LATER one is not: `quiet` must still exclude the pane entirely -- it
        # must never use the earlier, convertible timestamp to wrongly prove staleness while ignoring a
        # later, unconvertible one in the same run.
        _append({"ev": "pane_observed", "pane_id": "mixed", "revision": 1, "agent_status": "idle",
                 "ts": "2000-01-01T00:00:00"})
        _append({"ev": "pane_observed", "pane_id": "mixed", "revision": 1, "agent_status": "idle",
                 "ts": "0001-01-01T00:00:00"})
        code, out, exc = _run(["quiet", "--threshold-seconds", "1"])
        assert exc in (0, 1), f"quiet must never crash on a mixed-convertibility run: {out!r}"
        assert '"pane_id": "mixed"' not in out, (
            f"a pane with ANY unconvertible timestamp in its quiet run must never be reported quiet, "
            f"even when an earlier observation in the same run IS convertible: {out!r}")

        # herdr command failure -> ERR_HERDR (2), distinct from quiet's own 0/1, never silently "observed
        # nothing". No new rows must be appended either.
        _write_fake_herdr(bindir, fail=True)
        pre_len = len(_recs())
        code, out, exc = _run(["observe"])
        assert code == 1 and exc == ERR_HERDR, (
            f"a herdr command failure must exit with ERR_HERDR ({ERR_HERDR}): exc={exc}")
        assert len(_recs()) == pre_len, "a failed observe must not append any row"

        # malformed/unparseable JSON from herdr -> also ERR_HERDR, never a crash.
        _write_fake_herdr(bindir, raw_pane_list="not json at all", raw_agent_list="{}")
        code, out, exc = _run(["observe"])
        assert code == 1 and exc == ERR_HERDR, "unparseable JSON from herdr must exit ERR_HERDR, not crash"

        # CONFIRMED BUG (checker round 4): a deeply nested but otherwise SYNTACTICALLY VALID JSON
        # response (e.g. ~1100 levels of nested arrays) overflows Python's recursive JSON decoder with an
        # uncaught RecursionError, which is NOT a ValueError and so was NOT caught by the existing
        # unparseable-JSON handling above -- `observe` crashed with exit 1 and a traceback instead of the
        # designed ERR_HERDR path. Must be folded into the same ERR_HERDR handling as any other
        # unparseable herdr response.
        deeply_nested = "[" * 1100 + "]" * 1100
        _write_fake_herdr(bindir, raw_pane_list=deeply_nested, raw_agent_list="{}")
        code, out, exc = _run(["observe"])
        assert code == 1 and exc == ERR_HERDR, (
            f"deeply-nested-but-valid JSON from herdr must exit ERR_HERDR, not crash with RecursionError: "
            f"code={code} exc={exc} out={out!r}")

        # CONFIRMED BUG (checker, round 9): a herdr that exits 0 but emits an invalid UTF-8 byte (e.g. a
        # stray 0xff) in its stdout previously crashed with an uncaught UnicodeDecodeError at
        # subprocess.run's own text=True decode step, before _herdr_json's own json.loads try/except ever
        # ran -- `observe` exited 1 with a traceback instead of the designed ERR_HERDR path. Written
        # directly (not via _write_fake_herdr, which only shapes well-formed JSON payloads): `printf
        # '\xff'` emits one raw invalid-UTF-8 byte to stdout, then exits 0.
        invalid_utf8_herdr = """#!/usr/bin/env bash
if [ "$1" = "pane" ] && [ "$2" = "list" ]; then
printf '\\xff'
exit 0
fi
if [ "$1" = "agent" ] && [ "$2" = "list" ]; then
echo '{}'
exit 0
fi
echo "unexpected herdr args: $@" >&2
exit 1
"""
        herdr_script = bindir / "herdr"
        herdr_script.write_text(invalid_utf8_herdr)
        herdr_script.chmod(0o755)
        code, out, exc = _run(["observe"])
        assert code == 1 and exc == ERR_HERDR, (
            f"an invalid-UTF-8 byte in herdr's stdout must exit ERR_HERDR, not crash with "
            f"UnicodeDecodeError: code={code} exc={exc} out={out!r}")

        # CONFIRMED BUG (checker, round 1): syntactically VALID JSON that is missing the expected
        # top-level `result.panes`/`result.agents` shape (e.g. a bare `{}`, or a future herdr API shape
        # change) must ALSO raise ERR_HERDR -- it must never silently fall through to an empty snapshot
        # and report "observed 0 pane(s)" with exit 0, which would hide a real herdr-output problem
        # behind the exact false-clean signal this watchdog exists to avoid. Exercised for both calls
        # independently: pane list missing its shape (agent list well-formed), and vice versa.
        pre_len = len(_recs())
        _write_fake_herdr(bindir, raw_pane_list="{}", raw_agent_list=json.dumps(_agent_list_json([])))
        code, out, exc = _run(["observe"])
        assert code == 1 and exc == ERR_HERDR, (
            f"a bare {{}} `pane list` response (missing result.panes) must exit ERR_HERDR, not fall "
            f"through to an empty snapshot: exc={exc}")
        _write_fake_herdr(bindir, raw_pane_list=json.dumps(_pane_list_json([])), raw_agent_list="{}")
        code, out, exc = _run(["observe"])
        assert code == 1 and exc == ERR_HERDR, (
            f"a bare {{}} `agent list` response (missing result.agents) must exit ERR_HERDR, not fall "
            f"through to an empty snapshot: exc={exc}")
        assert len(_recs()) == pre_len, "neither bad-shape observe attempt must append any row"

        # COVERAGE GAP (checker, round 2 -> round 3): the above only tests the "key missing entirely"
        # branch of _require_list. A key that's PRESENT but the WRONG TYPE (e.g. `result.panes: null` or
        # `result.panes: "not-a-list"` -- a real herdr response reshape could plausibly do either) must
        # ALSO raise ERR_HERDR, never silently coerce or crash differently. Exercised for both calls
        # independently, with two different wrong-type shapes (null and a bare string) for extra
        # coverage.
        pre_len = len(_recs())
        _write_fake_herdr(bindir, raw_pane_list=json.dumps({"result": {"panes": None}}),
                           raw_agent_list=json.dumps(_agent_list_json([])))
        code, out, exc = _run(["observe"])
        assert code == 1 and exc == ERR_HERDR, (
            f"result.panes present but null (wrong type) must exit ERR_HERDR, not crash or silently "
            f"coerce: exc={exc}")
        _write_fake_herdr(bindir, raw_pane_list=json.dumps(_pane_list_json([])),
                           raw_agent_list=json.dumps({"result": {"agents": "not-a-list"}}))
        code, out, exc = _run(["observe"])
        assert code == 1 and exc == ERR_HERDR, (
            f"result.agents present but a bare string (wrong type) must exit ERR_HERDR, not crash or "
            f"silently coerce: exc={exc}")
        assert len(_recs()) == pre_len, "neither wrong-type-shape observe attempt must append any row"

        # per-ENTRY tolerance must still hold even though the TOP-LEVEL shape is now strictly enforced --
        # a single malformed pane/agent dict inside an otherwise well-shaped list is still just skipped,
        # never escalated to ERR_HERDR (that's the distinction _require_list's own docstring draws).
        _write_fake_herdr(bindir,
            _pane_list_json([{"pane_id": "pshape", "revision": 1, "agent_status": "idle"}]),
            _agent_list_json([{"revision": 1}]))  # agent entry missing pane_id -- tolerated, not an error
        code, out, exc = _run(["observe"])
        assert code == 0 and exc is None, (
            "a malformed INDIVIDUAL agent entry inside a well-shaped list must still be tolerated, not ERR_HERDR")

        # a pane entry missing pane_id must be skipped tolerantly, never crash the whole observe call --
        # other, well-formed entries in the same poll must still be recorded.
        _write_fake_herdr(bindir,
            _pane_list_json([
                {"revision": 1, "agent_status": "working"},  # missing pane_id -- malformed, skip
                {"pane_id": "p3", "revision": 1, "agent_status": "idle", "focused": False},
            ]),
            _agent_list_json([{"pane_id": "p3", "revision": 1, "agent_status": "idle", "state_change_seq": 1}]))
        pre_len = len(_recs())
        code, out, exc = _run(["observe"])
        assert code == 0 and exc is None, "a malformed pane entry must not crash observe"
        assert len(_recs()) == pre_len + 1, (
            "exactly the one well-formed entry must be appended, the malformed one skipped")

        # corruption surfacing: a hand-corrupted ledger line must be counted, not silently hidden.
        with LEDGER.open("a") as f:
            f.write("not json at all\n")
        bad_before = _BAD
        _recs()
        assert _BAD > bad_before, "a malformed ledger line must be counted as corruption"

        # CONFIRMED BUG (checker): a deeply-nested but SYNTACTICALLY VALID JSON line stored directly in
        # the ledger file (e.g. ~1100 levels of nested arrays) raises an uncaught RecursionError from
        # json.loads, not ValueError -- the existing `except ValueError` in _recs()'s own parse loop does
        # not catch it, so the whole read (and therefore `quiet`) crashed instead of treating the one
        # line as malformed like any other unparseable row.
        bad_before = _BAD
        with LEDGER.open("a") as f:
            f.write("[" * 1100 + "]" * 1100 + "\n")
        code, out, exc = _run(["quiet", "--threshold-seconds", "1"])
        assert exc in (0, 1), (
            f"a deeply-nested-but-valid JSON ledger line must never crash quiet with a RecursionError: {out!r}")
        _recs()
        assert _BAD > bad_before, "a deeply-nested JSON ledger line must be counted as malformed (_BAD)"
    finally:
        LEDGER = orig_ledger
        os.environ["PATH"] = orig_path
        shutil.rmtree(tmpdir, ignore_errors=True)


def _selfcheck_default_ledger_path():
    # Same cross-worktree-sharing regression as claim-ledger.py/progress-ledger.py's own
    # _selfcheck_default_ledger_path: a dispatcher (primary checkout) and a sub-supervisor (linked
    # worktree) must resolve to the IDENTICAL default ledger file with SM_PANE_LEDGER/SM_LOOP_STATE both
    # unset. Appends directly (bypassing `observe`, which needs a real or faked herdr) to isolate this
    # from herdr reachability entirely.
    tmp = tempfile.mkdtemp(prefix="pane-reaper-pathcheck-")
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

        env = {k: v for k, v in os.environ.items() if k not in ("SM_PANE_LEDGER", "SM_LOOP_STATE")}

        def _cli(cwd, argv):
            return subprocess.run([sys.executable, _SCRIPT_PATH] + argv, cwd=cwd, env=env,
                                   capture_output=True, text=True)

        p1 = _cli(repo, ["quiet", "--threshold-seconds", "99999"])
        assert p1.returncode == 0, (
            f"quiet against an empty/absent ledger from the primary checkout should succeed: {p1.stderr}")

        common_dir = subprocess.run(["git", "-C", repo, "rev-parse", "--git-common-dir"],
                                     capture_output=True, text=True, check=True).stdout.strip()
        common_dir_path = pathlib.Path(common_dir)
        if not common_dir_path.is_absolute():
            common_dir_path = pathlib.Path(repo) / common_dir_path
        expected = common_dir_path.resolve().parent / ".secondmate" / "panes.jsonl"
        expected.parent.mkdir(parents=True, exist_ok=True)
        with expected.open("a") as f:
            f.write(json.dumps({"ev": "pane_observed", "pane_id": "shared-pane", "revision": 1,
                                 "ts": time.strftime("%Y-%m-%dT%H:%M:%S")}) + "\n")

        p2 = _cli(wt, ["quiet", "--threshold-seconds", "99999"])
        assert p2.returncode == 0, (
            "a shared ledger with only one observation for a pane must still exit 0 (insufficient "
            f"history, never reported) from a DIFFERENT worktree's CWD: {p2.stderr}")
        assert expected.exists(), f"expected the shared default ledger to land at {expected}"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    p = argparse.ArgumentParser(description="detects (never acts on) quiet herdr panes")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("observe")

    q = sub.add_parser("quiet")
    q.add_argument("--threshold-seconds", required=True, type=int)

    sub.add_parser("selfcheck")

    args = p.parse_args(argv)

    if args.cmd == "observe":
        try:
            snapshot = _snapshot_panes()
        except _HerdrError as e:
            sys.stderr.write(f"ERROR: {e}\n")
            sys.exit(ERR_HERDR)
        ts = time.strftime("%Y-%m-%dT%H:%M:%S")
        with _ledger_lock():
            for pane_id, state in snapshot.items():
                rec = {"ev": "pane_observed", "pane_id": pane_id, "ts": ts}
                if state["revision"] is not None:
                    rec["revision"] = state["revision"]
                if state["agent_status"] is not None:
                    rec["agent_status"] = state["agent_status"]
                if state["focused"] is not None:
                    rec["focused"] = state["focused"]
                if state["state_change_seq"] is not None:
                    rec["state_change_seq"] = state["state_change_seq"]
                _append(rec)
        print(f"observed {len(snapshot)} pane(s)")

    elif args.cmd == "quiet":
        if not _valid_positive_number(args.threshold_seconds):
            sys.exit(f"invalid --threshold-seconds {args.threshold_seconds!r}: must be a finite number > 0")
        # read-only, no lock -- same lock-free precedent progress-ledger.py's own `stale` establishes.
        by_pane = _observations_by_pane()
        hits = find_quiet(by_pane, args.threshold_seconds)
        for h in hits:
            print(json.dumps(h))
        if _BAD:
            sys.stderr.write(
                f"WARNING: {_BAD} malformed line(s) in {LEDGER} -- ledger may be corrupt; reconcile manually.\n")
        sys.exit(1 if hits else 0)

    elif args.cmd == "selfcheck":
        assert _signature({"revision": 1, "agent_status": "idle", "state_change_seq": 2}) == (1, "idle", 2)
        assert find_quiet({}, 0) == [], "an empty observation set must report no hits"
        assert find_quiet({"a": [{"ts": "2026-01-01T00:00:00", "revision": 1}]}, 0) == [], (
            "a single-observation pane must never be reported, regardless of threshold")
        _selfcheck_live()
        _selfcheck_default_ledger_path()
        print("ok")


if __name__ == "__main__":
    main(sys.argv[1:])
