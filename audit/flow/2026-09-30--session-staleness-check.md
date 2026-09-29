## 2026-09-30 — session-staleness-check: wire doctor.sh's staleness detection into a SessionStart hook

Dispatched as a solo sub-agent-supervisor per the standard dispatch path (trigger: iterative + verifiable +
risky/outward-facing — a real SessionStart hook behavior change).

Plan Committee: the 6-model `bin/plan-committee.sh` round (out-dir `.secondmate/planning/session-staleness-check/`)
hit its 280s timeout mid-repo-exploration for every one of the 6 planners and produced no final synthesized
`.md` output — only raw `.md.jsonl` transcripts, preserved as-is. This was not retried with a longer timeout;
the maker's spec was instead synthesized directly from the human's own already-detailed task brief plus direct
reads of `bin/doctor.sh` (`_detect_secondmate_status`/`_detect_secondmate_staleness`), `bin/session-holds.sh`,
`bin/session-activate.sh`, and `hooks/hooks.json`. In parallel, an `adhd` cognitive-frame ideation fork (5
frames: 3am-on-call, regulator, speedrunner, inversion, ant-colony) independently converged on essentially the
same design and landed its write-up at `.secondmate/planning/adhd.md` — used as corroboration, not as the sole
source of the spec.

Maker routing: Claude maker (complex — judgment call between extending `session-activate.sh` vs. a new sibling
hook, plus exposing `doctor.sh`'s detection function without duplicating its SHA/version-diff logic, plus a
3-file doc-sync). Ran directly on the worktree's root pane (`herdr agent start sm-session-staleness-check --kind
claude --pane w43:p1`). One round only — the maker's own design (new `bin/session-staleness.sh` sibling hook +
`bin/doctor.sh --staleness-json` thin wrapper + `hooks/hooks.json` third `SessionStart` entry) matched the
`adhd` fork's converged recommendation, needed no fix-loop iteration. Committed as `ca36ceb`.

Checker: pi / `global.openai.gpt-5.6-terra`, run in a VISIBLE herdr pane (`w43:p2`, split off the maker's root
pane) per this repo's strict-checker-visible-pane policy (`HERDR_ENV=1`, no headless exception) — script written
to `/tmp/checker-session-staleness-check-r1.sh` and invoked via `herdr pane run` + `wait-output` per the
argv-to-PTY-line quoting caveat. Lenses implicitly covered per the envelope: qa/coverage, qa/risk-flagging,
redteam/access-control. Round 1 verdict: **pass**, 0 findings — no fix-loop needed.

Gate: `verify-gate.sh --worktree <wt> --base main --checked-sha ca36ceb80cc620775600323fad0ca09678551ad5 --test
"bash bin/doctor.sh --selfcheck && bash bin/session-staleness.sh --selfcheck"` → PASS (clean, non-empty vs main,
checker-current, tests green).

Hold: opened `b099cfaf` (task `session-staleness-check`, sha `ca36ceb80cc620775600323fad0ca09678551ad5`).
Answered `yes` by a genuine human (via the dispatching coordinator relay, independently re-verified by reading
the raw `decisions.jsonl` ledger record directly before acting on it, rather than trusting the relay alone).

Integrate: `bin/merge-sequencer.sh` merged `sm/session-staleness-check` -> `main` as
`eec2ab943de01d792fc5697a8cbc9c0adcc94ff1` (pushed to origin). Claim released. Teardown: herdr worktree/workspace
removed, branch `sm/session-staleness-check` deleted, checker pane already closed post-verdict.
`bin/teardown-check.sh` confirmed clean (worktree/branch/herdr/claim all clean).

Round count: 1 maker round, 1 checker round, 0 fix-loop iterations.
