## 2026-09-17 — maker-permission-mode-auto: Claude maker launch recipe --permission-mode acceptEdits → auto

- **Maker (pi/Qwen3-Coder-Next, medium thinking):** changed both Claude-maker launch recipes in `skills/secondmate/SKILL.md` from `--permission-mode acceptEdits` to `--permission-mode auto`, per direct human instruction (Opus temporarily unavailable, Sonnet 5 substituting as maker, human wants the same `auto` mode previously used for Opus). Clean on round 1.
- **Decisions:** confirmed `auto` is a real, valid CLI choice via `claude --help` before proceeding, rather than trusting the human's phrasing alone; confirmed via grep that no other file or launch site (including every pi-maker site, which use `--thinking`/`--extension`, not `--permission-mode`) needed the same change.
- **Checker findings resolved:** none — clean pass, zero findings, on the first round. A fully-scoped two-word text change with no ambiguity once the plan-committee's probes were resolved.
- **Gates:** verify-gate PASS at `f37065b` → human hold `4a0e6b41` answered `merge` → merged to main via `bin/merge-sequencer.sh` at `18a516e` → version bump correctly included this time (`0.1.19` → `0.1.20`) → full repo-wide selfcheck chain re-run clean (`ALL_OK`) → `claude plugin validate .` passed → torn down.
- **Escalations:** one genuine per-task merge hold (answered `merge`). No self-answered holds.
