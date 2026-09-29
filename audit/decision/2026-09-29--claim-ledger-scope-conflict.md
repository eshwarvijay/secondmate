## 2026-09-29 — Ship declared-scope+operation mechanism only; decline foremerge's SQLite/MCP/HTTP machinery

**Decision:** ship the declared-scope+operation conflict check inside `bin/claim-ledger.py` itself
(`--scope KIND:KEY=OPERATION` on `claim`/`steal`, new read-only `conflicts` subcommand, exit 0/1 signal),
rather than adopting `github.com/naw103/foremerge` (the Rust/SQLite/MCP tool this idea was stolen from).

**Rationale:** foremerge's actual contribution — requiring agents to *declare* an operation on a scope
rather than inferring it from prose (their own measurement: prose inference caught 1/10 real conflicts,
false-positived on 9/9 compatible pairs) — is a real, portable idea. Its Rust binary, SQLite event graph,
hash-chained ledger, and MCP/HTTP transport are not; they solve a distributed multi-transport problem this
repo does not have (single Python CLI, N=2-capped concurrency, single operator). The gap it targets is
real for this repo too: `claim-ledger.py` already prevents two supervisors claiming the same task-id, and
`merge-sequencer.sh`'s preflight is purely textual (`git merge-tree`) — neither catches two *different*
task-ids, in different worktrees, with no textual file overlap, that are semantically incompatible (one
guts an abstraction the other extends).

**Explicitly declined, with reasoning:**
- No SQLite, daemon, MCP server, HTTP API, or event-hash-chain — stayed inside the existing fcntl-locked
  JSONL idiom already in `claim-ledger.py`.
- No fuzzy/similarity scope matching (foremerge's Jaccard-token tiers) — exact case-sensitive string match
  only, per this task's explicit constraint.
- No new script file — extended `claim-ledger.py` in place.
- No auto-blocking — `conflicts` is a plain advisory callable; the dispatcher/human decides, matching this
  repo's existing "surface, don't gate" posture elsewhere (verify-gate, hold.py).
- No raising the existing N=2 concurrency cap.
- No `SKILL.md` fan-out-section wiring to actually declare `--scope`/call `conflicts` in this task — the
  mechanism ships; adoption into the documented dispatcher recipe is a deliberate, named follow-up, not a
  gap in this diff.

**Checker findings:** one real, CONFIRMED bug in round 1 — `_SCOPE_RE`'s `[^\s=]+` rejected whitespace in
a free-text scope, contradicting the plan's explicit "no new sanitization beyond `--owner`'s existing
posture" decision. Fixed in `a70dfc0` (widened to `[^=]+`, added a whitespace-scope selfcheck regression
case). Round 2: pass, no findings — checker independently drove a real-CLI operation matrix (all 7
declared operations x additive/destructive classification), verified `conflicts` never locks or mutates
the ledger (byte-identical ledger + no `.lock` file created), and confirmed the new selfcheck assertions
are fail-to-pass against the old (`6fc7ff2`) implementation, not just passing trivially.

**Gate:** PASS at `a70dfc060da1c8a521ed89dab7308d5951c37321` (clean, non-empty vs main, checker-current,
`selfcheck` green). One supervisor-side gate misfire (short SHA vs full SHA) — not a real refusal, self-
corrected on retry with the full 40-char SHA.

**Hold:** genuine human "yes" answer, SHA-bound to the exact checked commit, no self-answer.

**Residual/deferred (out of scope for this task, noted for later):** `SKILL.md`'s "Fan-out to concurrent
sub-supervisors" recipe does not yet call `--scope`/`conflicts` anywhere — the mechanism exists but is not
wired into the dispatcher flow. A future task should decide whether/how each sub-supervisor declares a
scope+operation on its own claim and checks the sibling's before launching.
