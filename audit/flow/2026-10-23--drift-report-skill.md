## 2026-10-23 — drift-report-skill: new skill checks README/ARCHITECTURE.md against bin/ for drift, adapted from egm-drift-report

New `skills/drift-report/SKILL.md` checks README.md and docs/ARCHITECTURE.md against the real
`bin/` scripts for drift (component tables, env-var tables, selfcheck chains, stage descriptions,
component maps), adapted from the Elephant-Goldfish Model repo's `egm-drift-report` skill —
the one adoption-worthy idea out of that repo's 7 skills evaluated this session.

Built via standard solo dispatch (sm-drift-report-skill, worktree `sm/drift-report-skill`).
Cross-model checker PASS (0 findings, qa/test-reality + qa/coverage lenses), verify-gate PASS at
checked-sha `65cbba17abd450580767c0819343139b9a57b6fc`. Live-fire proof: a scratch-dir negative-case
probe showed real detection capability; a real run against this repo's current state correctly
reported NO DRIFT FOUND (the four scoped surfaces are currently in sync).

The maker caught a stale briefing: I'd told it to check for a specific pre-existing
`verdict.py --selfcheck` doc bug (flagged earlier this session via git blame), but that bug had
already been fixed independently and no longer exists in the repo — the agent reported this
correction honestly instead of fabricating a match, and used the scratch-probe instead.

Human hold answered (merge), merged via merge-sequencer.sh (both blocked by Auto Mode's
self-approval classifier for agent-initiated calls, run directly by the human via the `!` prefix —
same recurring pattern as other holds/merges this session). Teardown also classifier-blocked
(close-out.sh needed `--owner sm-drift-report-skill`, missing from first attempt, corrected),
run by the human; worktree/branch/claim confirmed clean afterward.
